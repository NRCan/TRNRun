"""Simulation handles kept in sync with one trnrund daemon."""

import logging
import sqlite3
from contextlib import ExitStack
from dataclasses import replace
from pathlib import Path
from tempfile import TemporaryDirectory
from threading import Condition, Event, Lock, Thread, current_thread
from time import monotonic
from types import TracebackType
from typing import Final, Self

from trnrun.batch.display import Display, ProgressDisplay
from trnrun.batch.events import LogEvent, SimulationInfo, parse_log, parse_run
from trnrun.batch.simulation import Simulation
from trnrun.config import SimulationConfig
from trnrun.daemon import Daemon
from trnrun.database import TrnRunDatabase
from trnrun.process import DEFAULT_EXECUTABLE

logger = logging.getLogger(__name__)

DEFAULT_POLL_INTERVAL: Final[float] = 0.25


def _last_numeric_run_id(database: sqlite3.Connection) -> int:
    """Return the largest all-digit run ID in the database, or 0."""
    query = (
        "SELECT coalesce(max(CAST(run_id AS INTEGER)), 0) FROM runs WHERE run_id NOT GLOB '*[^0-9]*' AND run_id != ''"
    )
    return int(database.execute(query).fetchone()[0])


def _last_log_id(database: sqlite3.Connection) -> int:
    """Return the largest log ID in the database, or 0."""
    return int(database.execute("SELECT coalesce(max(log_id), 0) FROM logs").fetchone()[0])


class SimulationManager:
    """Own one trnrund daemon and keep its simulations' handles in sync.

    A background thread reads the runs that changed from the daemon's database
    every ``poll_interval`` seconds, applies them to their handles, shows the
    changes on the display, then stops tracking finished handles and wakes
    ``wait()``. It is the only thread that changes a handle, so reading one
    never waits.

    The runs are kept in a temporary database, deleted on ``shutdown()``.
    Pass ``database`` to keep them in that SQLite file instead, which outlives
    the manager; its directory must exist. A manager reusing it numbers its
    runs after those already there, and never deletes them.

    By default the manager shows its runs with a ``ProgressDisplay``. Pass
    ``display=False`` to show them yourself, for example from a GUI timer
    reading the handles, or any ``Display``, which the background thread then
    updates instead. The display is closed on ``shutdown()``.

    When syncing stops, because the daemon exited, a database read failed, or
    the manager shut down, ``wait()`` raises a RuntimeError naming the cause
    for unfinished runs instead of hanging, and later submissions raise it
    too. Handles keep their
    last state. Runs already submitted go on until ``shutdown()``, which stops
    the daemon.

    Call ``add()``, ``cancel()``, and ``shutdown()`` from the thread that
    created the manager. Use ``Daemon`` directly when an application needs to
    control polling, run IDs, or the database itself.
    """

    def __init__(
        self,
        max_concurrent: int | None = None,
        *,
        database: str | Path | None = None,
        trnrun_path: str | Path | None = None,
        executable: str | Path = DEFAULT_EXECUTABLE,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        display: bool | Display = True,
    ) -> None:
        """Start the daemon and the background thread syncing its runs.

        max_concurrent defaults to one less than the CPU count, at least 1.
        trnrun_path and executable are passed to ``Daemon``. Startup failures
        raise as they do there.
        """
        if not poll_interval > 0:
            raise ValueError("poll_interval must be positive")
        # Unwound by shutdown: the daemon first, then the temporary database, then the display.
        self._resources: ExitStack = ExitStack()
        self.display: Display | None
        if display is True:
            self.display = ProgressDisplay()
        else:
            self.display = None if display is False else display
        if self.display is not None:
            _ = self._resources.callback(self.display.close)
        try:
            if database is None:
                temporary = self._resources.enter_context(
                    TemporaryDirectory(prefix="trnrun-", ignore_cleanup_errors=True),
                )
                database = Path(temporary) / "runs.sqlite3"
            self._daemon: Daemon = self._resources.enter_context(
                Daemon(database, max_concurrent=max_concurrent, trnrun_path=trnrun_path, executable=executable),
            )
            # Read before any submission; the poller reads only what comes after.
            next_id = _last_numeric_run_id(self._daemon.database) + 1
            self._revision: int = self._daemon.database.get_latest_revision()
            self._log_id: int = _last_log_id(self._daemon.database)
        except BaseException:
            self._resources.close()
            raise
        # Serializes requests, since a Daemon serves one thread; held only to talk to it.
        self._daemon_lock: Lock = Lock()
        # Guards _simulations, _next_id, and _failure; never held while talking to the daemon.
        self._lock: Lock = Lock()
        # Notified when a run stops being tracked, or syncing stops; wakes wait().
        self._changed: Condition = Condition(self._lock)
        # Unfinished runs, and finished ones until their final display update; only the poller removes them.
        self._simulations: dict[str, Simulation] = {}
        # After the runs a reused database holds, since a run ID can never be reused in it.
        self._next_id: int = next_id
        # The error that stopped syncing, raised by every later call.
        self._failure: Exception | None = None

        self._poll_interval: float = poll_interval
        # Set once, by shutdown; it also marks the manager closed.
        self._stop: Event = Event()
        self._poller: Thread = Thread(target=self._poll, name="trnrun-manager", daemon=True)
        self._poller.start()

    @property
    def database_path(self) -> Path:
        """Return the absolute path of the database holding the runs."""
        return self._daemon.database_path

    @property
    def active(self) -> list[Simulation]:
        """Return the unfinished simulations in submission order, including queued ones."""
        with self._lock:
            return [simulation for simulation in self._simulations.values() if not simulation.is_finished]

    def add(self, deck_file: str | Path, config: SimulationConfig | None = None) -> Simulation:
        """Queue a deck and return its handle, kept in sync from now on.

        The run starts once a worker is free. ``config`` defaults to
        ``SimulationConfig()``; it is copied, so it can be changed and reused
        for later submissions. A relative ``deck_file`` resolves from the
        current working directory.

        Raises
        ------
        FileNotFoundError
            If the configured TRNSYS executable is missing.
        ValueError
            If the daemon rejects the run, such as for a missing deck or one
            that is not a ``.dck`` or ``.trd`` file.
        RuntimeError
            If the manager is closed, or the error that stopped syncing.
        """
        config = SimulationConfig() if config is None else replace(config)
        trnrun_args = config.to_cli_args()

        with self._lock:
            self._check()
            simulation = Simulation(Path(deck_file).absolute(), config, self._next_id)
            self._next_id += 1
            # Tracked before it is sent, so the first poll reporting it finds it.
            self._simulations[str(simulation.id)] = simulation
        try:
            with self._daemon_lock:
                self._daemon.add(str(simulation.id), simulation.deck_path, trnrun_args)
        except BaseException:
            with self._changed:
                _ = self._simulations.pop(str(simulation.id), None)
                self._changed.notify_all()
            raise
        return simulation

    def cancel(self, simulation: Simulation) -> None:
        """Stop a queued or running simulation; it finishes as CANCELLED shortly after.

        A finished simulation is left unchanged, keeping its real outcome.

        Raises
        ------
        ValueError
            If the simulation is unfinished but was not added to this manager.
        RuntimeError
            If the manager is closed, or the error that stopped syncing.
        """
        with self._lock:
            self._check()
            self._check_owned(simulation)
            if not self._is_pending(simulation):
                return  # Finished: keep its real outcome.
        with self._daemon_lock:
            self._daemon.cancel(str(simulation.id))

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
        RuntimeError
            If runs are unfinished when the manager is closed, or the error
            that stopped syncing, such as the daemon exiting.
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
        """Stop the daemon, cancelling unfinished runs, then release everything.

        Unfinished handles keep their last state, and waiting for them raises
        that the manager is closed. A temporary database is deleted, and the
        display is closed. Later calls do nothing.
        """
        with self._changed:
            if self._stop.is_set():
                return
            self._stop.set()
            self._changed.notify_all()
        # Joined first, so its database reader is closed before a temporary database is deleted.
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
        return self._simulations.get(str(simulation.id)) is simulation

    def _check_owned(self, simulation: Simulation) -> None:
        """Raise ValueError for an unfinished simulation this manager does not track; the caller holds the lock."""
        if not self._is_pending(simulation) and not simulation.is_finished:
            raise ValueError(f"Simulation {simulation.id} was not added to this manager")

    def _check(self) -> None:
        """Raise RuntimeError if the manager is closed or stopped syncing; the caller holds the lock."""
        if self._stop.is_set():
            raise RuntimeError("SimulationManager is closed")
        if self._failure is not None:
            # A fresh error each time, so tracebacks do not pile up on the recorded one.
            raise RuntimeError(f"SimulationManager stopped syncing: {self._failure}") from self._failure

    def _poll(self) -> None:
        """Sync every poll interval until shutdown or the first failed sync."""
        reader: TrnRunDatabase | None = None
        try:
            # Its own connection: SQLite connections stay in the thread that opened them.
            reader = TrnRunDatabase(self._daemon.database_path)
            while not self._stop.wait(self._poll_interval):
                self._sync(reader)
        except Exception as error:  # noqa: BLE001 - any failure stops syncing
            self._fail(error)
        finally:
            if reader is not None:
                reader.close()

    def _fail(self, error: Exception) -> None:
        """Record why syncing stopped, so waiting for unfinished runs and later calls raise ``error``."""
        with self._changed:
            if self._stop.is_set():
                return  # Shut down meanwhile; waiters already raise that the manager is closed.
            self._failure = error
            self._changed.notify_all()
        logger.error("TRNRun manager stopped syncing simulations", exc_info=error)

    def _daemon_exit(self) -> RuntimeError | None:
        """Return the error describing how the daemon exited, or None while it runs."""
        with self._daemon_lock:
            try:
                self._daemon.check()
            except RuntimeError as error:
                return error
        return None

    def _read_changes(self, reader: TrnRunDatabase) -> tuple[dict[str, SimulationInfo], dict[str, list[LogEvent]]]:
        """Return the runs and logs saved since the last read, by run ID, and advance the cursors."""
        run_rows = reader.get_changed_runs(self._revision)
        # Read after the runs, so the logs saved with each of their rows are included.
        log_rows = reader.get_new_logs(self._log_id)

        infos = {row["run_id"]: parse_run(row) for row in run_rows}
        logs: dict[str, list[LogEvent]] = {}
        for row in log_rows:
            logs.setdefault(row["run_id"], []).append(parse_log(row))
        if run_rows:
            self._revision = run_rows[-1]["revision"]
        if log_rows:
            self._log_id = log_rows[-1]["log_id"]
        return infos, logs

    def _sync(self, reader: TrnRunDatabase) -> None:
        """Read once what changed, apply it to the handles, show it, then release finished ones.

        A display failure is logged and never stops syncing. Raises the
        daemon's exit, after applying what it saved, since it can no longer
        finish the remaining runs.
        """
        with self._lock:
            if not self._simulations:
                return
        # Checked before reading, so a daemon found exited saved everything read below.
        exit_error = self._daemon_exit()
        infos, logs = self._read_changes(reader)

        changed: list[Simulation] = []
        finished: list[Simulation] = []
        with self._lock:
            for run_id in infos.keys() | logs.keys():
                simulation = self._simulations.get(run_id)
                if simulation is None:
                    continue
                info = infos.get(run_id)
                simulation.apply(info, logs.get(run_id, []))
                if info is not None:
                    changed.append(simulation)
                    if simulation.is_finished:
                        finished.append(simulation)
        changed.sort(key=lambda simulation: simulation.id)  # Read in the order they last changed.

        if changed and self.display is not None:
            try:
                self.display.update(changed)
            except Exception:
                logger.exception("TRNRun display failed to update")

        # Kept tracked until displayed, so wait() returns only after their final lines.
        with self._changed:
            for simulation in finished:
                _ = self._simulations.pop(str(simulation.id), None)
            self._changed.notify_all()
        if exit_error is not None:
            raise exit_error
