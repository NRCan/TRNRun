"""Simulation handles kept in sync with one trnrund daemon."""

import sqlite3
from contextlib import ExitStack, suppress
from dataclasses import replace
from pathlib import Path
from threading import Condition, Event, Lock, Thread, current_thread
from time import monotonic
from types import TracebackType
from typing import Final, Literal, Self

from trnrun.core.daemon import DEFAULT_TRNRUN, DEFAULT_TRNRUND, Daemon
from trnrun.core.database import read_changes
from trnrun.core.errors import ClosedError, DaemonExitedError, SyncError
from trnrun.core.records import Changes, LogEvent, SimulationState
from trnrun.core.settings import SimulationSettings
from trnrun.display import Display, ProgressDisplay
from trnrun.simulation import Simulation

DEFAULT_REFRESH_INTERVAL: Final[float] = 0.1
_STOP_CHECK: Final[float] = 0.1  # Longest the background thread waits before checking for shutdown.
_LIFECYCLE: Final[list[SimulationState]] = list(SimulationState)  # QUEUED, RUNNING, FINISHED, in order.


class SimulationManager:
    """Own one trnrund daemon and keep its simulations' handles in sync.

    A background thread waits for the daemon to announce saved changes,
    reads them from its database, applies them to their handles, shows them
    on the display, then stops tracking finished handles and wakes
    ``wait()``. It is the only thread that changes a handle, so reading one
    never waits. It syncs at most once every ``refresh_interval`` seconds,
    gathering the changes saved meanwhile.

    The runs are kept in a temporary database, deleted on ``shutdown()``.
    Pass ``database_path`` to keep them in that SQLite file instead, which outlives
    the manager; its directory must exist. A manager reusing it adds its runs
    in a new session and never deletes the existing ones.

    By default the manager shows its runs with a ``ProgressDisplay``. Pass
    ``display=False`` to show them yourself, for example from a GUI timer reading the handles, or
    any ``Display``, which the background thread then updates instead. The
    display is closed on ``shutdown()``.

    When syncing stops, because the daemon exited or a database read failed,
    ``wait()`` raises ``DaemonExitedError`` or ``SyncError`` for unfinished
    runs instead of hanging, and later submissions raise it too. After
    ``shutdown()`` they raise ``ClosedError``. Handles keep their last state.

    Call ``add()``, ``cancel()``, and ``shutdown()`` from the thread that
    created the manager. Use ``Daemon`` directly when an application needs to
    control polling or the database itself.
    """

    def __init__(
        self,
        database_path: str | Path | None = None,
        *,
        max_concurrent: int | None = None,
        trnrund_path: str | Path = DEFAULT_TRNRUND,
        trnrun_path: str | Path = DEFAULT_TRNRUN,
        refresh_interval: float = DEFAULT_REFRESH_INTERVAL,
        display: bool | Display = True,
    ) -> None:
        """Start the daemon and the background thread syncing its runs.

        max_concurrent defaults to one less than the CPU count, at least 1.
        database_path, trnrund_path and trnrun_path are passed to ``Daemon``.
        Startup failures raise as they do there.
        """
        if refresh_interval < 0:
            raise ValueError("refresh_interval must not be negative")
        # Unwound by shutdown: the daemon, with a temporary database, then the display.
        self._resources: ExitStack = ExitStack()
        self.display: Display | None = ProgressDisplay() if display is True else (display or None)
        if self.display is not None:
            _ = self._resources.callback(self.display.close)
        try:
            self._daemon: Daemon = self._resources.enter_context(
                Daemon(
                    database_path,
                    max_concurrent=max_concurrent,
                    trnrund_path=trnrund_path,
                    trnrun_path=trnrun_path,
                ),
            )
        except BaseException:
            self._resources.close()
            raise
        # Guards _simulations and _failure, and is held across each submission and each read of
        # the database, so the background thread never reads a run before it is tracked.
        self._lock: Lock = Lock()
        # Notified when a run stops being tracked, or syncing stops; wakes wait().
        self._changed: Condition = Condition(self._lock)
        # Unfinished runs, and finished ones until their final display update, by run ID; only
        # the background thread removes them.
        self._simulations: dict[int, Simulation] = {}
        # The error that stopped syncing, raised by every later call.
        self._failure: Exception | None = None

        self._refresh_interval: float = refresh_interval
        # Set once, by shutdown; it also marks the manager closed.
        self._stop: Event = Event()
        self._poller: Thread = Thread(target=self._poll, name="trnrun-manager", daemon=True)
        self._poller.start()

    @property
    def database_path(self) -> Path:
        """Return the absolute path of the database holding the runs."""
        return self._daemon.database_path

    @property
    def session_id(self) -> int:
        """Return the daemon session the manager's runs belong to in the database."""
        return self._daemon.session_id

    @property
    def active(self) -> list[Simulation]:
        """Return the unfinished simulations in submission order, including queued ones."""
        with self._lock:
            return [simulation for simulation in self._simulations.values() if not simulation.is_finished]

    def add(
        self,
        deck_file: str | Path,
        settings: SimulationSettings | None = None,
        *,
        label: str | None = None,
        wait_for: SimulationState | Literal["QUEUED", "RUNNING", "FINISHED"] = SimulationState.QUEUED,
    ) -> Simulation:
        """Queue a deck and return its handle, kept in sync from now on.

        The run starts once a slot is free. ``settings`` defaults to
        ``SimulationSettings()``, which keeps TRNRun's defaults; it is copied,
        so it can be changed and reused for later submissions. ``label`` is
        saved with the run in the database. A relative ``deck_file`` resolves
        from the current working directory.

        Returns once the handle reaches ``wait_for``, a ``SimulationState`` or
        its name, or a later state. The default ``QUEUED`` returns at once;
        ``RUNNING`` also returns for a run that finished without starting;
        ``FINISHED`` returns as ``wait()`` does, after the final display update.

        Raises
        ------
        ValueError
            If ``wait_for`` is not a ``SimulationState`` name; nothing is queued.
        FileNotFoundError
            If the configured TRNSYS executable is missing.
        RequestRejectedError
            If the daemon rejects the run, such as for a missing deck or one
            that is not a ``.dck`` or ``.trd`` file.
        ClosedError
            If the manager was shut down.
        DaemonExitedError, SyncError
            The error that stopped syncing, including while waiting for ``wait_for``.
        """
        settings = SimulationSettings() if settings is None else replace(settings)
        deck_file = Path(deck_file).absolute()
        wait_for = SimulationState(wait_for)

        with self._changed:
            self._check()
            run_id = self._daemon.add(deck_file, settings, label=label)
            simulation = Simulation(run_id, deck_file, settings)
            self._simulations[run_id] = simulation
            # Each sync notifies, and waiting releases the lock so the background thread can sync.
            while not self._has_reached(simulation, wait_for):
                self._check()
                _ = self._changed.wait()
        return simulation

    def cancel(self, simulation: Simulation) -> None:
        """Stop a queued or running simulation; it finishes as CANCELLED shortly after.

        A finished simulation is left unchanged, keeping its real outcome.

        Raises
        ------
        ValueError
            If the simulation is unfinished but was not added to this manager.
        ClosedError
            If the manager was shut down.
        DaemonExitedError, SyncError
            The error that stopped syncing.
        """
        with self._lock:
            self._check()
            self._check_owned(simulation)
            if not self._is_pending(simulation):
                return  # Finished: keep its real outcome.
        self._daemon.cancel(simulation.run_id)

    def wait(self, simulation: Simulation | None = None, *, timeout: float | None = None) -> None:
        """Block until ``simulation`` has finished, or every run if None, including those added meanwhile.

        Returns only after their final display updates; failed runs finish
        too, so check ``Simulation.succeeded``. Returns at once for runs that
        already finished, even after shutdown.

        Raises
        ------
        TimeoutError
            If runs are unfinished after ``timeout`` seconds.
        ValueError
            If the simulation is unfinished but was not added to this manager.
        ClosedError
            If runs are unfinished when the manager is shut down.
        DaemonExitedError, SyncError
            The error that stopped syncing, such as the daemon exiting.
        """
        deadline = None if timeout is None else monotonic() + timeout
        with self._changed:
            if simulation is not None:
                self._check_owned(simulation)
            while self._is_pending(simulation):
                self._check()
                remaining = None if deadline is None else deadline - monotonic()
                if remaining is not None and remaining <= 0:
                    raise TimeoutError("Simulations did not finish within the timeout")
                _ = self._changed.wait(remaining)

    def shutdown(self) -> None:
        """Stop the daemon, interrupting unfinished runs, then release everything.

        Unfinished handles keep their last state, and waiting for them raises
        ``ClosedError``. A temporary database is deleted, and the display is
        closed. Later calls do nothing.
        """
        with self._changed:
            if self._stop.is_set():
                return
            self._stop.set()
            self._changed.notify_all()
        # Joined first: it reads the database that closing the daemon may delete.
        if current_thread() is not self._poller:
            self._poller.join()
        self._resources.close()

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
        """Shut the manager down when leaving the context."""
        self.shutdown()

    def _is_pending(self, simulation: Simulation | None) -> bool:
        """Return whether ``wait(simulation)`` must keep waiting; the caller holds the lock."""
        if simulation is None:
            return bool(self._simulations)
        return self._simulations.get(simulation.run_id) is simulation

    def _has_reached(self, simulation: Simulation, state: SimulationState) -> bool:
        """Return whether ``simulation`` is at ``state`` or later; the caller holds the lock."""
        if state is SimulationState.FINISHED:
            return not self._is_pending(simulation)  # As wait(): only after the final display update.
        return _LIFECYCLE.index(simulation.state) >= _LIFECYCLE.index(state)

    def _check_owned(self, simulation: Simulation) -> None:
        """Raise ValueError for an unfinished simulation this manager does not track; the caller holds the lock."""
        if not self._is_pending(simulation) and not simulation.is_finished:
            raise ValueError(f"Simulation {simulation.run_id} was not added to this manager")

    def _check(self) -> None:
        """Raise if the manager is closed or stopped syncing; the caller holds the lock."""
        if self._stop.is_set():
            raise ClosedError("SimulationManager is closed")
        failure = self._failure
        if failure is None:
            return
        # A fresh error each time, so tracebacks do not pile up on the recorded one.
        if isinstance(failure, DaemonExitedError):
            raise DaemonExitedError(failure.exit_code, failure.diagnostics) from failure
        raise SyncError(f"SimulationManager stopped syncing: {failure}") from failure

    def _poll(self) -> None:
        """Sync after each announced change until shutdown or the first failed sync."""
        connection: sqlite3.Connection | None = None
        try:
            # Its own connection: SQLite connections stay in the thread that opened them. It
            # starts where the daemon did, so a run that finishes before its first sync is seen.
            connection = self._daemon.connect()
            position = Changes(revision=self._daemon.start_revision, log_id=self._daemon.start_log_id)
            while not self._stop.is_set():
                if not self._daemon.wait_for_changes(position.revision, _STOP_CHECK) or self._stop.is_set():
                    continue
                position = self._sync(connection, position)
                _ = self._stop.wait(self._refresh_interval)  # Gathers the changes saved meanwhile.
        except Exception as error:  # noqa: BLE001 - any failure stops syncing
            self._fail(error)
        finally:
            if connection is not None:
                connection.close()

    def _fail(self, error: Exception) -> None:
        """Record why syncing stopped, so waiting for unfinished runs and later calls raise ``error``."""
        with self._changed:
            if self._stop.is_set():
                return  # Shut down meanwhile; waiters already raise that the manager is closed.
            self._failure = error
            self._changed.notify_all()

    def _sync(self, connection: sqlite3.Connection, position: Changes) -> Changes:
        """Read what changed after ``position``, apply it to the handles, show it, then release finished ones.

        Returns what was read, the position to read after next time. A
        display failure is ignored and never stops syncing.
        """
        changed: list[Simulation] = []
        finished: list[Simulation] = []
        with self._lock:
            changes = read_changes(connection, position.revision, position.log_id)
            infos = {info.run_id: info for info in changes.runs}
            logs: dict[int, list[LogEvent]] = {}
            for log in changes.logs:
                logs.setdefault(log.run_id, []).append(log)
            for run_id in infos.keys() | logs.keys():
                simulation = self._simulations.get(run_id)
                if simulation is None:
                    continue
                info = infos.get(run_id)
                simulation._apply(info, logs.get(run_id, []))  # noqa: SLF001 # pyright: ignore[reportPrivateUsage] - the manager is its only writer
                if info is not None:
                    changed.append(simulation)
                    if simulation.is_finished:
                        finished.append(simulation)
        changed.sort(key=lambda simulation: simulation.run_id)

        if changed and self.display is not None:
            with suppress(Exception):
                self.display.update(changed)

        # Kept tracked until displayed, so wait() returns only after their final lines.
        with self._changed:
            for simulation in finished:
                _ = self._simulations.pop(simulation.run_id, None)
            self._changed.notify_all()
        return changes
