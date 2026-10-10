"""Simulation handles kept in sync with one TRNRun daemon."""

from __future__ import annotations

import contextlib
import logging
from collections.abc import Sequence
from dataclasses import replace
from pathlib import Path
from threading import Event, Lock, Thread, current_thread
from time import monotonic
from types import TracebackType
from typing import Final, Protocol, Self

from trnrun.client import DEFAULT_MAX_CONCURRENT, DaemonClient
from trnrun.config import BUNDLED_TRNRUN_PATH, BUNDLED_TRNRUND_PATH, SimulationConfig
from trnrun.convenience.simulation import Simulation

logger = logging.getLogger(__name__)

DEFAULT_POLL_INTERVAL: Final[float] = 0.25


class Display(Protocol):
    """What ``SimulationManager`` drives, from its background thread."""

    def update(self, changed: Sequence[Simulation]) -> None:
        """Show the runs that changed in the latest poll, in submission order."""

    def close(self) -> None:
        """Release output resources; the manager calls it once, on shutdown."""


class SimulationManager:
    """Own one TRNRun daemon and keep its simulations' handles in sync.

    A background thread pulls the runs that changed every ``poll_interval``
    seconds, applies them to their handles, shows the changes on the display,
    then settles and stops tracking finished handles. It is the only thread
    that changes a handle, so reading one never waits.

    This convenience layer owns polling, handles, waiting, and cleanup, not
    scheduling or application workflows. Use ``DaemonClient`` directly when
    an application needs to control polling or retain state itself.

    By default the manager shows its runs with a ``ProgressDisplay``, requiring
    the optional ``trnrun[display]`` dependencies. Pass
    ``display=False`` to show them yourself, for example from a GUI timer
    reading the handles, or any ``Display``, which the background thread then
    updates instead. The display is closed on ``shutdown()``.

    When syncing stops, because a pull failed or the manager shut down, every
    unfinished handle is settled with that error, so ``wait()`` and
    ``Simulation.wait()`` raise it instead of hanging. Handles keep their last
    reply. A failed pull also kills the daemon, so its runs never go on
    untracked, and later submissions fail.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        *,
        trnrun_path: str | Path = BUNDLED_TRNRUN_PATH,
        trnrund_path: str | Path = BUNDLED_TRNRUND_PATH,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        display: bool | Display = True,
    ) -> None:
        if not poll_interval > 0:
            raise ValueError("poll_interval must be positive")
        # Before the daemon, so a display that cannot start leaves nothing to clean up.
        self.display: Display | None
        if display is True:
            from trnrun.convenience.display import ProgressDisplay  # noqa: PLC0415 - optional display dependency

            self.display = ProgressDisplay()
        else:
            self.display = None if display is False else display
        self._client: DaemonClient = DaemonClient(max_concurrent, trnrun_path=trnrun_path, trnrund_path=trnrund_path)
        # Guards the two fields below; never held while talking to the daemon.
        self._lock: Lock = Lock()
        # Runs awaiting settlement (including their final display update), or abandoned after a failed pull.
        self._simulations: dict[str, Simulation] = {}
        self._next_id: int = 1

        self._poll_interval: float = poll_interval
        # Set once, by shutdown; it also marks the manager closed.
        self._stop: Event = Event()
        self._poller: Thread = Thread(target=self._poll, name="trnrun-manager", daemon=True)
        self._poller.start()

    @property
    def active(self) -> list[Simulation]:
        """Return the unfinished simulations in submission order, including queued ones."""
        with self._lock:
            return [simulation for simulation in self._simulations.values() if not simulation.is_finished]

    def add(self, deck_file: str | Path, config: SimulationConfig) -> Simulation:
        """Submit a deck to the daemon's queue and return its handle, kept in sync from now on.

        The run starts once a worker is free.

        Raises
        ------
        FileNotFoundError
            If the configured TRNSYS executable is missing.
        ValueError
            If the daemon rejects the run, such as for a missing deck or one
            that is not a ``.dck`` or ``.trd`` file.
        RuntimeError
            If the manager is closed, or the daemon exited or was killed after
            a failed pull.
        """
        # Copy, so the caller can reuse and change `config` for later submissions.
        config = replace(config)
        trnrun_args: list[str] = config.to_cli_args()

        with self._lock:
            self._check()
            simulation = Simulation(Path(deck_file).absolute(), config, self._next_id)
            self._next_id += 1
            # Tracked before it is sent, so the first pull reporting it finds it.
            self._simulations[str(simulation.id)] = simulation
        try:
            self._client.add(str(simulation.id), simulation.deck_path, trnrun_args)
        except BaseException:
            with self._lock:
                _ = self._simulations.pop(str(simulation.id), None)
            raise
        return simulation

    def wait(self, timeout: float | None = None) -> None:
        """Block until every run, including those added meanwhile, has finished.

        Returns only after their final display updates. Use
        ``Simulation.wait()`` to wait for one run.

        Raises
        ------
        TimeoutError
            If runs are unfinished after ``timeout`` seconds.
        RuntimeError
            If the manager is closed, or the error of a failed pull, which
            settled the unfinished runs with it.
        """
        deadline = None if timeout is None else monotonic() + timeout
        while True:
            with self._lock:
                self._check()
                active = list(self._simulations.values())
            if not active:
                return
            for simulation in active:
                simulation.wait(None if deadline is None else max(deadline - monotonic(), 0.0))

    def shutdown(self) -> None:
        """Kill the daemon and its runs, stop syncing, settle unfinished handles, and close the display.

        Unfinished handles keep their last reply, and their ``wait()`` raises
        that the manager is closed. Later calls do nothing.
        """
        with self._lock:
            if self._stop.is_set():
                return
            # Stopped before the kill, so the poller takes its failing pull for shutdown.
            self._stop.set()
            abandoned = list(self._simulations.values())
            self._simulations.clear()
        closed = RuntimeError("SimulationManager is closed")
        for simulation in abandoned:
            simulation.settle(closed)
        try:
            # Kill before joining, so a pull blocked on the daemon fails at once.
            self._client.kill()
        finally:
            if current_thread() is not self._poller:
                self._poller.join()
            if self.display is not None:
                self.display.close()

    def __enter__(self) -> Self:
        """Enter the manager before shutdown."""
        with self._lock:
            self._check()
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Release the daemon when leaving the context."""
        self.shutdown()

    def _check(self) -> None:
        """Raise if the manager is closed; the caller holds the lock."""
        if self._stop.is_set():
            raise RuntimeError("SimulationManager is closed")

    def _poll(self) -> None:
        """Sync every poll interval until shutdown or the first failed pull."""
        while not self._stop.wait(self._poll_interval):
            try:
                _ = self._sync()
            except Exception as error:
                if self._stop.is_set():
                    return  # Shutdown interrupted the pull.
                logger.exception("TRNRun manager stopped syncing simulations")
                # The daemon is gone or no longer understood: kill it, so no run goes on untracked.
                with contextlib.suppress(Exception):
                    self._client.kill()
                # Left in `_simulations`, so `wait()` meets them and raises the error.
                with self._lock:
                    abandoned = list(self._simulations.values())
                for simulation in abandoned:
                    simulation.settle(error)
                return

    def _sync(self) -> list[Simulation]:
        """Pull once and return the handles that changed.

        Applies each reply, shows the changes on the display, then settles and
        stops tracking finished handles. A display failure is logged and never
        stops syncing.
        """
        with self._lock:
            if not self._simulations:
                return []
        replies = self._client.pull()

        changed: list[Simulation] = []
        finished: dict[str, Simulation] = {}
        with self._lock:
            for run_id, reply in replies.items():
                simulation = self._simulations.get(run_id)
                if simulation is None:
                    continue
                simulation.apply(reply)
                changed.append(simulation)
                if simulation.is_finished:
                    finished[run_id] = simulation

        if changed and self.display is not None:
            try:
                self.display.update(changed)
            except Exception:
                logger.exception("TRNRun display failed to update")

        # Keep finished runs tracked until displayed and settled, so even a new wait sees them.
        with self._lock:
            for run_id, simulation in finished.items():
                simulation.settle()
                _ = self._simulations.pop(run_id, None)
        return changed
