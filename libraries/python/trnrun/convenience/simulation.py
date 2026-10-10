"""State for one simulation submitted to the TRNRun daemon.

The manager's background thread is the only writer. Each daemon reply replaces
the handle's ``info`` as a whole, so one read of ``info`` is a coherent view of
every field, and each property reads it once. The handle also accumulates the
complete log history, and settles once: when the run finishes, or when the
manager stops syncing it, so ``wait()`` never hangs.
"""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from threading import Event

from trnrun.config import SimulationConfig
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SettingEvent,
    SimulationReply,
    SimulationState,
    SimulationStatus,
    StatusEvent,
)


class Simulation:
    """Daemon state for one submitted simulation.

    The submission is ``id``, ``deck_path``, and ``config``, from which the
    runner arguments are built. ``info`` is the daemon's latest reply; the
    properties from ``state`` to ``succeeded`` read it, naming the ``setting``,
    ``status``, and ``config`` events ``setting_event``, ``status_event``, and
    ``config_event``, while ``status`` gives the status alone. ``logs``,
    ``log_count``, ``is_accepted``, ``is_running``, and ``is_finished`` are
    conveniences.

    Separate property reads may reflect different replies; read ``info`` once
    when several fields must agree. Public input attributes ``id``,
    ``deck_path``, and ``config`` remain caller-owned and should not be mutated
    concurrently.
    """

    def __init__(
        self,
        deck_path: str | Path,
        config: SimulationConfig,
        sim_id: int,
    ) -> None:
        """Initialize a queued simulation with an empty log history."""
        self.id: int = sim_id
        self.deck_path: Path = Path(deck_path)
        self.config: SimulationConfig = config

        self._info: SimulationReply = SimulationReply(SimulationState.QUEUED)
        self._logs: list[LogEvent] = []
        self._settled: Event = Event()
        self._error: Exception | None = None

    def apply(self, reply: SimulationReply) -> None:
        """Append the reply's logs and replace ``info`` with the reply.

        The manager calls this with each daemon reply, which carries only the
        log entries that arrived since its previous poll; read the handle
        instead.
        """
        # Logs first, so a handle that reads finished already holds its final entries.
        self._logs.extend(reply.logs)
        self._info = replace(reply, logs=())

    def settle(self, error: Exception | None = None) -> None:
        """Release ``wait()``, with the error that stopped syncing if the run never finished.

        The manager calls this after the finished reply or when it stops
        syncing; read the handle instead. Only the first call counts, so a
        later shutdown keeps the error of a failed pull.
        """
        if self._settled.is_set():
            return
        self._error = error
        self._settled.set()

    def wait(self, timeout: float | None = None) -> None:
        """Block until the run finishes.

        Raises
        ------
        TimeoutError
            If it has not finished within ``timeout`` seconds.
        RuntimeError
            If its manager stopped syncing it first, such as on shutdown or
            when the daemon exited: the error that stopped it.
        """
        if not self._settled.wait(timeout):
            raise TimeoutError(f"Simulation {self.id} did not finish within the timeout")
        if self._error is not None:
            raise self._error

    @property
    def info(self) -> SimulationReply:
        """Return the daemon's latest reply, frozen; its ``logs`` is empty, see ``logs``."""
        return self._info

    @property
    def state(self) -> SimulationState:
        """Return the daemon lifecycle state."""
        return self._info.state

    @property
    def exit_code(self) -> int | None:
        """Return the runner exit code, or None until it exits or if it never launched."""
        return self._info.exit_code

    @property
    def error(self) -> str:
        """Return the daemon execution error, or an empty string."""
        return self._info.error

    @property
    def setting_event(self) -> SettingEvent | None:
        """Return the latest runner setting event."""
        return self._info.setting

    @property
    def status(self) -> SimulationStatus | None:
        """Return the latest runner status."""
        status = self._info.status
        return status.status if status is not None else None

    @property
    def status_event(self) -> StatusEvent | None:
        """Return the latest status event, including its message."""
        return self._info.status

    @property
    def config_event(self) -> ConfigEvent | None:
        """Return the latest simulation configuration event."""
        return self._info.config

    @property
    def progress(self) -> ProgressEvent | None:
        """Return the latest progress event."""
        return self._info.progress

    @property
    def logs(self) -> list[LogEvent]:
        """Return a copy of all log events, oldest first."""
        return list(self._logs)

    @property
    def notices(self) -> int:
        """Return the notice count."""
        return self._info.notices

    @property
    def warnings(self) -> int:
        """Return the warning count."""
        return self._info.warnings

    @property
    def fatals(self) -> int:
        """Return the fatal count."""
        return self._info.fatals

    @property
    def succeeded(self) -> bool:
        """Return whether the run finished with `DONE`, exit code 0, and no error."""
        return self._info.succeeded

    @property
    def log_count(self) -> int:
        """Return the total received log count."""
        return len(self._logs)

    @property
    def is_accepted(self) -> bool:
        """Return whether a daemon worker slot was reserved for the run."""
        return self._info.state is not SimulationState.QUEUED

    @property
    def is_running(self) -> bool:
        """Return whether the daemon lifecycle state is RUNNING."""
        return self._info.state is SimulationState.RUNNING

    @property
    def is_finished(self) -> bool:
        """Return whether the daemon finished the run; its logs are then complete."""
        return self._info.state is SimulationState.FINISHED
