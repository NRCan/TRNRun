"""The typed records read from a trnrund database: runs, their TRNRun events, and their logs.

The event types mirror trnrund's ``events.nim``. ``STATUS`` and ``SETTING``
have no record: they are fields of ``SimulationInfo``.
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from pathlib import Path


# -----------------------------------------------------------------
# Enums
# -----------------------------------------------------------------
class SimulationState(StrEnum):
    """Daemon lifecycle, ``QUEUED → RUNNING → FINISHED``; a run that never starts goes straight to ``FINISHED``."""

    QUEUED = "QUEUED"
    RUNNING = "RUNNING"
    FINISHED = "FINISHED"


class SimulationStatus(StrEnum):
    """Runner-reported simulation status."""

    PENDING = "PENDING"
    LAUNCHING = "LAUNCHING"
    RUNNING = "RUNNING"
    DONE = "DONE"
    CANCELLED = "CANCELLED"
    ERROR = "ERROR"
    TIMEOUT = "TIMEOUT"
    STALLED = "STALLED"


class LogSeverity(StrEnum):
    """Severity of a TRNSYS log entry."""

    NOTICE = "Notice"
    WARNING = "Warning"
    FATAL = "Fatal"


# -----------------------------------------------------------------
# Events
# -----------------------------------------------------------------
@dataclass(frozen=True)
class ProgressEvent:
    """The run's latest completion and timing.

    Attributes
    ----------
    time : float
        Current simulation time, in simulated hours.
    percent : float
        Completion of the run as a fraction from 0 to 1.
    elapsed_ms : float
        Wall-clock milliseconds elapsed since the run started.
    eta_ms : float
        Estimated wall-clock milliseconds remaining.
    """

    time: float
    percent: float
    elapsed_ms: float
    eta_ms: float


@dataclass(frozen=True)
class ConfigEvent:
    """The simulation's start, stop and time step, in simulated hours."""

    start: float
    stop: float
    step: float


@dataclass(frozen=True)
class LogEvent:
    """One TRNSYS log entry; the fields after ``time`` are None unless TRNSYS attached them.

    Attributes
    ----------
    log_id : int
        Position among every run's logs; grows with each entry.
    run_id : int
        Run the entry belongs to.
    time : float
        Simulation time of the message, in simulated hours.
    unit_id, type_id : int or None
        Unit, and its type, that emitted the message.
    """

    log_id: int
    run_id: int
    severity: LogSeverity
    time: float
    unit_id: int | None = None
    type_id: int | None = None
    message_code: int | None = None
    message: str | None = None
    information: str | None = None


# -----------------------------------------------------------------
# Runs
# -----------------------------------------------------------------
@dataclass(frozen=True)
class SimulationInfo:
    """One run's row in the daemon's database; a field is None where its column is NULL.

    Attributes
    ----------
    run_id : int
        ID the daemon assigned; never reused in its database.
    state : SimulationState
        Daemon lifecycle.
    deck_file : Path
        Absolute deck path.
    session_id : int
        Daemon start that added the run.
    label : str or None
        Tag the run was added with.
    revision : int
        Revision of the run's latest save.
    trnrun_args : list of str
        TRNRun options the run was added with.
    status, status_message : SimulationStatus or None, str or None
        TRNRun's latest status and its detail. TRNRun can report ``DONE``
        before ``state`` is ``FINISHED``.
    progress, config : ProgressEvent or None, ConfigEvent or None
        Latest event of each kind.
    setting : dict or None
        Settings TRNRun applied, its defaults included, keyed by flag name.
    notices, warnings, fatals : int
        Log entries saved so far, by severity.
    succeeded : bool or None
        Whether it finished with ``DONE``, exit code 0 and no error.
    exit_code : int or None
        TRNRun's exit code.
    error : str or None
        Execution error reported by the daemon.
    submitted_at, started_at, finished_at : datetime or None
        UTC times; ``started_at`` stays None for a run that never started.
    """

    run_id: int
    state: SimulationState
    deck_file: Path
    session_id: int = 0
    label: str | None = None
    revision: int = 0
    trnrun_args: list[str] = field(default_factory=list[str])
    status: SimulationStatus | None = None
    status_message: str | None = None
    progress: ProgressEvent | None = None
    config: ConfigEvent | None = None
    setting: dict[str, object] | None = None
    notices: int = 0
    warnings: int = 0
    fatals: int = 0
    succeeded: bool | None = None
    exit_code: int | None = None
    error: str | None = None
    submitted_at: datetime | None = None
    started_at: datetime | None = None
    finished_at: datetime | None = None

    @property
    def is_finished(self) -> bool:
        """Return whether the daemon finished the run; its logs are then complete."""
        return self.state is SimulationState.FINISHED


@dataclass(frozen=True)
class Changes:
    """What ``read_changes()`` read, and where to read next.

    Attributes
    ----------
    runs : list of SimulationInfo
        Latest snapshot of each changed run, in the order they last changed.
    logs : list of LogEvent
        New log entries, oldest first.
    revision, log_id : int
        Positions to pass to the next ``read_changes()``.
    """

    runs: list[SimulationInfo] = field(default_factory=list[SimulationInfo])
    logs: list[LogEvent] = field(default_factory=list[LogEvent])
    revision: int = 0
    log_id: int = 0

    def __bool__(self) -> bool:
        """Return whether anything changed."""
        return bool(self.runs or self.logs)
