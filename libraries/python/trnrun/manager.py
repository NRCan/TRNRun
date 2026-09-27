"""Simulation management through one TRNRun Queue process.

Queue output is read and folded on a background thread, so every `Simulation`
is current the moment the queue reports something, whether or not the caller is
inside a manager call. Callers poll a `Simulation` from any thread at their own
cadence, or block on `wait()` when they only need the results.

Lock ordering: this manager never holds its own lock while taking a
simulation's, so the two can be acquired independently without deadlock.
"""

from __future__ import annotations

import logging
import os
import queue
import threading
from collections.abc import Iterator
from dataclasses import replace
from pathlib import Path
from types import TracebackType
from typing import Final, Self

from trnrun.config import BUNDLED_TRNRUNQ_PATH, SimulationConfig
from trnrun.display import DisplayCallback, NullDisplay, create_display
from trnrun.events import EventParseError, TrnRunEvent, parse_stream_line
from trnrun.process import QueueProcess
from trnrun.simulation import Simulation

logger = logging.getLogger(__name__)

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)

# Bounds how long `follow()` blocks before re-checking its exit conditions.
_FOLLOW_POLL_SECONDS: Final[float] = 0.1


class SimulationManager:
    """Submit and monitor simulations through one `trnrunq.exe` process.

    A background reader thread drains queue stdout and folds each event into
    the matching `Simulation`. Callers may read a `Simulation` from any thread
    at any time without calling into the manager first; hold
    `Simulation.lock` to read several of its fields as one consistent view.

    Parameters
    ----------
    max_concurrent : int
        Maximum simultaneous runners. Defaults to the logical CPU count minus
        one, with a minimum of one.
    refresh_interval : float
        Minimum seconds between built-in display refreshes. Nonpositive values
        disable the display, which is what a caller rendering its own progress
        should pass.
    trnrunq_path : str or Path
        Queue executable to start. Defaults to the bundled `trnrunq.exe`.

    Notes
    -----
    The built-in display is driven from the reader thread so it stays live
    while the caller is busy. Pass `refresh_interval=0` to disable it entirely
    before rendering your own.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        refresh_interval: float = 1.0,
        *,
        trnrunq_path: str | Path = BUNDLED_TRNRUNQ_PATH,
    ) -> None:
        """Start the queue process and begin reading its output."""
        self._display: DisplayCallback = create_display(refresh_interval)
        self._lock: threading.Lock = threading.Lock()
        self._simulations: list[Simulation] = []
        self._active: dict[str, Simulation] = {}
        self._next_id: int = 1
        self._closed: bool = False
        self._fault: BaseException | None = None
        self._followers: int = 0
        self._updates: queue.SimpleQueue[Simulation] = queue.SimpleQueue()

        self._idle: threading.Event = threading.Event()
        self._idle.set()

        # Constructed last: the reader thread starts immediately and calls back
        # into `_on_line`, which requires every attribute above to exist.
        self._process: QueueProcess = QueueProcess(
            trnrunq_path,
            max_concurrent,
            self._on_line,
            self._on_eof,
        )

    # -----------------------------------------------------------------
    # Inspection
    # -----------------------------------------------------------------
    @property
    def simulations(self) -> list[Simulation]:
        """Return submitted simulations in submission order.

        Includes runs the queue has not accepted yet, so a caller rendering its
        own display can show them as pending.
        """
        with self._lock:
            return list(self._simulations)

    @property
    def succeeded(self) -> list[Simulation]:
        """Return simulations that completed successfully."""
        return [simulation for simulation in self.simulations if simulation.succeeded]

    @property
    def failed(self) -> list[Simulation]:
        """Return simulations that completed without succeeding."""
        return [simulation for simulation in self.simulations if simulation.is_finished and not simulation.succeeded]

    @property
    def active_count(self) -> int:
        """Return the number of submitted runs that have not completed."""
        with self._lock:
            return len(self._active)

    @property
    def has_active_runs(self) -> bool:
        """Return whether any submitted run is still outstanding."""
        return self.active_count > 0

    # -----------------------------------------------------------------
    # Submission
    # -----------------------------------------------------------------
    def submit(self, deck_file: str | Path, config: SimulationConfig) -> Simulation:
        """Submit a simulation and return immediately, without waiting for acceptance.

        The returned simulation starts unaccepted; poll its `state` to watch it
        progress, or call its `wait()` to block on just that run. Prefer this
        over `add()` whenever the caller drives its own display, because
        acceptance can take arbitrarily long once `max_concurrent` is saturated.

        Raises `RuntimeError` after shutdown has started, `FileNotFoundError`
        for a missing deck, and re-raises any fault recorded by the reader
        thread.
        """
        self._raise_if_faulted()
        if self._closed:
            raise RuntimeError("Cannot add simulations after shutdown has started")

        deck_path = Path(deck_file).absolute()
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        config = replace(config)
        config.validate()

        with self._lock:
            simulation = Simulation(deck_path, config, self._next_id)
            self._next_id += 1
            run_id = str(simulation.id)
            # Register before sending: the reader thread can observe ACCEPTED
            # before `send()` returns and would otherwise drop the event.
            self._active[run_id] = simulation
            self._simulations.append(simulation)
            self._idle.clear()

        try:
            self._process.send(
                {
                    "runID": run_id,
                    "deckFile": str(deck_path),
                    "runnerPath": str(config.trnrun_path),
                    "runnerArgs": config.to_cli_args(),
                },
            )
        except BaseException:
            self._discard(run_id, simulation)
            raise

        return simulation

    def add(
        self,
        deck_file: str | Path,
        config: SimulationConfig,
        timeout: float | None = None,
    ) -> Simulation:
        """Submit a simulation and block until a queue worker accepts it.

        Equivalent to `submit()` followed by `Simulation.wait_accepted()`. With
        `max_concurrent` saturated this blocks until a worker frees up; use
        `submit()` instead from a thread that must stay responsive.

        Raises `TimeoutError` if `timeout` elapses before acceptance.
        """
        simulation = self.submit(deck_file, config)
        if not simulation.wait_accepted(timeout):
            raise TimeoutError(f"Simulation {simulation.id} was not accepted within {timeout} seconds")
        self._raise_if_faulted()
        return simulation

    # -----------------------------------------------------------------
    # Waiting
    # -----------------------------------------------------------------
    def wait(self, simulation: Simulation | None = None, timeout: float | None = None) -> bool:
        """Block until the selected simulation, or all simulations, finish.

        Returns False if `timeout` elapsed first. Waiting no longer drives
        reading, so this is interruptible and safe to call with a short timeout
        from a render loop. Re-raises any fault recorded by the reader thread,
        including queue stdout closing with runs still outstanding.
        """
        self._raise_if_faulted()

        if simulation is not None:
            self._require_owned(simulation)
            finished = simulation.wait(timeout)
        else:
            finished = self._idle.wait(timeout)

        self._raise_if_faulted()
        return finished

    def follow(self, simulation: Simulation | None = None) -> Iterator[Simulation]:
        """Yield each simulation as its state changes.

        With `simulation` provided, only that run is yielded and iteration ends
        when it completes; otherwise iteration ends once no runs are
        outstanding. Updates that occurred before iteration started are not
        replayed, and updates are only buffered while someone is following.

        Raises `ValueError` if the selected simulation does not belong to this
        manager, and `RuntimeError` if shutdown has started.
        """
        if self._closed:
            raise RuntimeError("Cannot follow simulations after shutdown has started")
        self._raise_if_faulted()

        if simulation is not None:
            self._require_owned(simulation)
            if simulation.is_finished:
                return

        with self._lock:
            self._followers += 1
        try:
            while True:
                self._raise_if_faulted()
                if self._closed:
                    raise RuntimeError("Cannot follow simulations after shutdown has started")
                if simulation is None:
                    if not self.has_active_runs:
                        return
                elif simulation.is_finished:
                    return

                try:
                    updated = self._updates.get(timeout=_FOLLOW_POLL_SECONDS)
                except queue.Empty:
                    continue

                if simulation is None or updated is simulation:
                    yield updated
        finally:
            with self._lock:
                self._followers -= 1
                last = self._followers == 0
            if last:
                self._drain_updates()

    # -----------------------------------------------------------------
    # Lifecycle
    # -----------------------------------------------------------------
    def shutdown(self) -> None:
        """Kill and reap the queue without waiting for simulations to finish.

        Call `wait` first to finish runs and collect their results. Outstanding
        runs are abandoned rather than failed, so they are never mistaken for
        successes. The manager stays closed if cleanup fails or is interrupted;
        later calls do nothing.
        """
        with self._lock:
            if self._closed:
                return
            self._closed = True

        try:
            self._process.shutdown()
        finally:
            self._display.close()

    def __enter__(self) -> Self:
        """Enter the manager context before shutdown has started."""
        if self._closed:
            raise RuntimeError("Cannot enter a manager after shutdown has started")
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Kill the queue and release resources when leaving the manager context."""
        self.shutdown()

    # -----------------------------------------------------------------
    # Reader thread
    # -----------------------------------------------------------------
    def _on_line(self, line: str) -> None:
        """Fold one queue stdout line into its simulation. Runs on the reader thread."""
        try:
            self._route(line)
        except Exception as error:  # noqa: BLE001 - a fold or display failure must not stop draining
            self._record_fault(error)

    def _route(self, line: str) -> None:
        """Parse one line and hand it to the simulation it belongs to."""
        try:
            parsed = parse_stream_line(line)
        except EventParseError:
            logger.debug("dropped malformed queue line: %r", line, exc_info=True)
            return

        if parsed is None:
            return

        run_id, event = parsed
        with self._lock:
            simulation = self._active.get(run_id)
        if simulation is None:
            return

        self._apply(run_id, simulation, event)

    def _apply(self, run_id: str, simulation: Simulation, event: TrnRunEvent) -> None:
        """Apply one routed event, then update bookkeeping and the display."""
        was_accepted = simulation.is_accepted
        if not simulation.apply_event(event):
            return

        finished = simulation.is_finished
        if finished:
            self._discard(run_id, simulation)

        if self._followers:
            self._updates.put(simulation)

        if finished:
            self._display.simulation_finished(simulation)
        elif simulation.is_accepted and not was_accepted:
            self._display.simulation_started(simulation)
        else:
            self._display.refresh()

    def _on_eof(self) -> None:
        """Release every waiter when queue stdout closes. Runs on the reader thread."""
        with self._lock:
            outstanding = list(self._active.values())
            run_ids = list(self._active)
            self._active.clear()
            self._idle.set()
            closing = self._closed

        for simulation in outstanding:
            simulation.abandon()

        # A caller-initiated shutdown kills the queue on purpose; only an
        # unexpected close with work in flight is a fault.
        if outstanding and not closing:
            self._fault = RuntimeError(
                f"TRNRun queue closed before accepting or completing run IDs: {', '.join(run_ids)}",
            )

    # -----------------------------------------------------------------
    # Helpers
    # -----------------------------------------------------------------
    def _record_fault(self, error: BaseException) -> None:
        """Record the first reader-thread failure and stop driving the display.

        Draining and folding continue so runs already in flight still finish;
        the caller learns about the failure from its next manager call. The
        display is dropped because a display that raised once will raise on
        every following event.
        """
        logger.exception("TRNRun queue reader failed", exc_info=error)
        if self._fault is None:
            self._fault = error
        self._display = NullDisplay()

    def _discard(self, run_id: str, simulation: Simulation) -> None:
        """Drop a run from the active set, releasing `wait()` once none remain."""
        with self._lock:
            if self._active.get(run_id) is simulation:
                del self._active[run_id]
            if not self._active:
                self._idle.set()

    def _drain_updates(self) -> None:
        """Discard buffered updates once nobody is following."""
        while True:
            try:
                _ = self._updates.get_nowait()
            except queue.Empty:
                return

    def _require_owned(self, simulation: Simulation) -> None:
        """Reject a simulation that this manager did not create."""
        with self._lock:
            owned = any(simulation is candidate for candidate in self._simulations)
        if not owned:
            raise ValueError("Simulation does not belong to this manager")

    def _raise_if_faulted(self) -> None:
        """Re-raise a fault recorded by the reader thread."""
        if self._fault is not None:
            raise self._fault
