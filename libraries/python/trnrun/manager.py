"""Simulation handles kept current from one TRNRun daemon."""

from __future__ import annotations

import contextlib
import logging
from collections import deque
from collections.abc import Callable
from dataclasses import replace
from pathlib import Path
from threading import Condition, Event, Thread, current_thread
from types import TracebackType
from typing import Final, Self

from trnrun.client import DEFAULT_MAX_CONCURRENT, DaemonClient
from trnrun.config import BUNDLED_TRNRUN_PATH, BUNDLED_TRNRUND_PATH, SimulationConfig
from trnrun.display import ProgressDisplay, Renderer
from trnrun.events import SimulationReply, SimulationState, SimulationStatus, StatusEvent
from trnrun.simulation import Simulation

logger = logging.getLogger(__name__)

DEFAULT_POLL_INTERVAL: Final[float] = 0.25
DEFAULT_REFRESH_INTERVAL: Final[float] = 1.0
DECK_SUFFIXES: Final[frozenset[str]] = frozenset({".dck", ".trd"})


class SimulationManager:
    """Submit simulations to one TRNRun daemon and keep their handles current.

    A background thread updates the handles every ``poll_interval`` seconds,
    so they keep moving whether or not anyone waits. Each update asks the
    daemon only for the runs changed since the previous one, with only their
    new logs, so its cost follows activity rather than the number of runs, and
    removes finished runs from the daemon and from ``active``. ``update()``
    does the same at once.

    By default the manager shows its runs with a ``ProgressDisplay``, closed
    on ``shutdown()``. Pass ``display=False`` to show them yourself, for
    example in a GUI, or a ``Renderer`` to draw the built-in display elsewhere.

    Methods may be called from any thread; read display fields with
    ``Simulation.snapshot()``. ``client`` sends daemon requests directly, but
    must not ``add`` or ``remove`` runs on the manager's behalf. A failed
    request raises from the call that made it; handles keep their last reply.
    A failed background update stops polling and is kept in ``failure``.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        *,
        trnrun_path: str | Path = BUNDLED_TRNRUN_PATH,
        trnrund_path: str | Path = BUNDLED_TRNRUND_PATH,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        display: bool | Renderer = True,
        refresh_interval: float = DEFAULT_REFRESH_INTERVAL,
    ) -> None:
        if not poll_interval > 0:
            raise ValueError("poll_interval must be positive")
        if not refresh_interval > 0:
            raise ValueError("refresh_interval must be positive")
        self.client: DaemonClient = DaemonClient(max_concurrent, trnrun_path=trnrun_path, trnrund_path=trnrund_path)
        # Guards the fields below, keeps each update whole, and wakes waiters after it.
        self._condition: Condition = Condition()
        # Tracked unfinished runs by run ID, in submission order, including those not sent yet.
        self._simulations: dict[str, Simulation] = {}
        # The tracked runs a worker took, ACCEPTED or RUNNING, by run ID, in the order seen to start.
        # At most about `max_concurrent`, so readers never scan the whole queue.
        self._started: dict[str, Simulation] = {}
        # Runs added without waiting, with their runner arguments, in the order to send them.
        self._pending: deque[tuple[Simulation, list[str]]] = deque()
        self._next_id: int = 1
        # Daemon revision the handles are current up to; the next update asks for later changes.
        self._revision: int = 0
        self._closed: bool = False
        self._failure: Exception | None = None

        self.display: ProgressDisplay | None = None
        if display is not False:
            try:
                renderer = None if display is True else display
                self.display = ProgressDisplay(self, refresh_interval=refresh_interval, renderer=renderer)
            except BaseException:
                # Best-effort cleanup must preserve the original display error.
                with contextlib.suppress(Exception):
                    self.client.kill()
                raise

        self._poll_interval: float = poll_interval
        self._stop: Event = Event()
        self._poller: Thread = Thread(target=self._poll, name="trnrun-manager", daemon=True)
        self._poller.start()

    @property
    def active(self) -> list[Simulation]:
        """Return tracked unfinished simulations in submission order, including queued ones."""
        with self._condition:
            return list(self._simulations.values())

    @property
    def started(self) -> list[Simulation]:
        """Return the unfinished simulations a worker took, ``ACCEPTED`` or ``RUNNING``, in the order they started.

        Unlike ``active``, this never includes queued runs, so it stays as
        small as ``max_concurrent`` however many runs wait.
        """
        with self._condition:
            return list(self._started.values())

    @property
    def failure(self) -> Exception | None:
        """Return the error that stopped background updates, such as the daemon exiting, or None."""
        with self._condition:
            return self._failure

    def add(
        self,
        deck_file: str | Path,
        config: SimulationConfig,
        *,
        wait_for: SimulationState | None = SimulationState.QUEUED,
        timeout: float | None = None,
    ) -> Simulation:
        """Submit a simulation and return its handle once it reaches ``wait_for``.

        ``wait_for`` is the state, or any later one, to wait for: ``QUEUED``,
        the default, returns once the daemon has the run, and ``ACCEPTED``,
        ``RUNNING``, or ``FINISHED`` wait longer. A run that fails to launch
        goes from ``ACCEPTED`` to ``FINISHED``, which also satisfies
        ``RUNNING``. ``None`` returns at once and leaves sending to the
        background thread; if the daemon then rejects the run, its handle
        finishes as an ``ERROR`` instead of raising. Runs are sent in the order
        they are added, whatever each one waits for.

        Raises
        ------
        FileNotFoundError
            If the deck or the configured TRNSYS executable is missing.
        ValueError
            If ``wait_for`` is not a ``SimulationState``, the deck is not a
            ``.dck`` or ``.trd`` file, or the daemon rejects the submission.
        TimeoutError
            If the run has not reached ``wait_for`` within ``timeout`` seconds;
            it stays submitted.
        RuntimeError
            If the manager is closed or the daemon exited, or the error that
            stopped background updates while waiting.
        """
        target = None if wait_for is None else SimulationState(wait_for)
        deck_path: Path = Path(deck_file).absolute()
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        if deck_path.suffix.lower() not in DECK_SUFFIXES:
            raise ValueError(f"Expected a .dck or .trd deck, got: {deck_path}")
        # Copy, so the caller can reuse and change `config` for later submissions.
        config = replace(config)
        trnrun_args: list[str] = config.to_cli_args()

        with self._condition:
            self._check_open()
            simulation = Simulation(deck_path, config, self._next_id)
            self._next_id += 1
            entry = (simulation, trnrun_args)
            self._pending.append(entry)
            self._simulations[str(simulation.id)] = simulation
            if target is None:
                return simulation

            try:
                self._send_pending(owner=simulation)
            except BaseException:
                # Unsent, the run is forgotten, as if never added.
                if entry in self._pending:
                    self._pending.remove(entry)
                    del self._simulations[str(simulation.id)]
                raise
            if target is not SimulationState.QUEUED:
                order = list(SimulationState)
                reached = order.index(target)
                self._wait_until(
                    lambda: order.index(simulation.state) >= reached,
                    timeout,
                    f"Simulation did not reach {target} within the timeout",
                )
        return simulation

    def update(self) -> list[Simulation]:
        """Update tracked handles from the daemon now, then forget finished runs.

        The background thread already does this every ``poll_interval``
        seconds. Runs added without waiting are sent first. Returns the
        handles that changed, including those that finished and those the
        daemon rejected, in the order they changed.

        Raises
        ------
        RuntimeError
            If the manager is closed or the daemon exited.
        """
        with self._condition:
            self._check_open()
            try:
                return self._update()
            finally:
                self._condition.notify_all()

    def wait(self, *simulations: Simulation, timeout: float | None = None) -> None:
        """Block until the given simulations, or all tracked ones, have finished.

        Raises
        ------
        ValueError
            If an unfinished simulation does not belong to this manager.
        TimeoutError
            If they have not finished within ``timeout`` seconds.
        RuntimeError
            If the manager is closed or the daemon exited, or the error that
            stopped background updates.
        """

        def finished() -> bool:
            if simulations:
                return all(simulation.is_finished for simulation in simulations)
            return not self._simulations

        with self._condition:
            self._check_open()
            for simulation in simulations:
                if not simulation.is_finished and self._simulations.get(str(simulation.id)) is not simulation:
                    raise ValueError("Simulation does not belong to this manager")
            self._wait_until(finished, timeout, "Simulations did not finish within the timeout")

    def shutdown(self) -> None:
        """Kill the daemon and its runs, close the display, and stop tracking them.

        Handles keep their last reply; unfinished ones never finish. Later
        calls do nothing. Calls racing from two threads may both kill the
        daemon, which is harmless.
        """
        if self._closed:
            return
        # Stop first, so the poller takes the failure of its last request for shutdown.
        self._stop.set()
        self._closed = True
        try:
            # Kill before taking the lock, so an update blocked on the daemon fails at once.
            self.client.kill()
        finally:
            try:
                # The display only reads handles, which the kill leaves as they were.
                if self.display is not None:
                    self.display.close()
            finally:
                with self._condition:
                    self._simulations.clear()
                    self._started.clear()
                    self._pending.clear()
                    self._condition.notify_all()
                if current_thread() is not self._poller:
                    self._poller.join()

    def __enter__(self) -> Self:
        """Enter the manager before shutdown."""
        if self._closed:
            raise RuntimeError("SimulationManager is closed")
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Release the daemon when leaving the context."""
        self.shutdown()

    def _check_open(self) -> None:
        """Raise if the manager is closed."""
        if self._closed:
            raise RuntimeError("SimulationManager is closed")

    def _poll(self) -> None:
        """Update every poll interval until shutdown or the first failure."""
        while not self._stop.wait(self._poll_interval):
            try:
                _ = self.update()
            except Exception as error:
                if self._stop.is_set():
                    return  # Shutdown interrupted the update.
                logger.exception("TRNRun manager stopped updating simulations")
                with self._condition:
                    self._failure = error
                    self._condition.notify_all()
                return

    def _wait_until(self, done: Callable[[], bool], timeout: float | None, timeout_message: str) -> None:
        """Wait until ``done()``, raising if the manager closes or stops updating first.

        The caller holds the condition, which every update notifies.
        """
        _ = self._condition.wait_for(lambda: self._closed or self._failure is not None or done(), timeout)
        # Closed first: shutdown forgets every run, which would look finished.
        self._check_open()
        if done():
            return
        if self._failure is not None:
            raise self._failure
        raise TimeoutError(timeout_message)

    def _send_pending(self, owner: Simulation | None = None) -> list[Simulation]:
        """Send runs added without waiting, in order, and return those the daemon rejected.

        The caller holds the condition. A rejected run is forgotten: ``owner``,
        the run whose ``add`` is sending, raises the daemon's ``ValueError``,
        and any other finishes as an ``ERROR``, since nobody waits to catch it.
        Any other failure propagates, leaving the unsent runs pending.
        """
        rejected: list[Simulation] = []
        while self._pending:
            simulation, trnrun_args = self._pending[0]
            try:
                self.client.add(str(simulation.id), simulation.deck_path, trnrun_args)
            except ValueError as error:
                _ = self._pending.popleft()
                del self._simulations[str(simulation.id)]
                if simulation is owner:
                    raise
                status = StatusEvent(SimulationStatus.ERROR, str(error))
                _ = simulation.apply(SimulationReply(SimulationState.FINISHED, error=str(error), status=status))
                rejected.append(simulation)
                continue
            _ = self._pending.popleft()
        return rejected

    def _update(self) -> list[Simulation]:
        """Update tracked handles once and return those that changed; the caller holds the condition.

        Runs added without waiting are sent first. The cursor advances only
        once every change is applied, so a failed update is repeated in full
        next time, which handles absorb.
        """
        changed = self._send_pending()
        if not self._simulations:
            return changed

        changes = self.client.changes(self._revision)
        for run_id, reply in changes.simulations.items():
            simulation = self._simulations.get(run_id)
            if simulation is None:
                continue  # Not this manager's run, such as one added through `client`.
            if simulation.apply(reply):
                changed.append(simulation)
            if reply.state is SimulationState.FINISHED:
                # The finished reply carried the final logs, so nothing is left to fetch.
                self.client.remove(run_id)
                del self._simulations[run_id]
                _ = self._started.pop(run_id, None)
            elif reply.state is not SimulationState.QUEUED:
                _ = self._started.setdefault(run_id, simulation)
        self._revision = changes.revision
        return changed
