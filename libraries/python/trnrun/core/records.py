"""The typed records trnrund replies with: runs, their TRNRun events, and their logs.

The event types mirror trnrund's ``events.nim``. ``STATUS`` and ``SETTING``
have no record: they are fields of ``SimulationInfo``, as are the run's logs.
``parse_run`` turns the run object of a reply into a record.
"""

# pyright: reportAny=false, reportExplicitAny=false

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from typing import Any


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
    time : float
        Simulation time of the message, in simulated hours.
    unit_id, type_id : int or None
        Unit, and its type, that emitted the message.
    """

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
    """One run as trnrund reported it; a field is None where trnrund replied ``null``.

    Attributes
    ----------
    run_id : int
        ID the daemon assigned; never reused while it runs.
    state : SimulationState
        Daemon lifecycle.
    deck_file : Path
        Absolute deck path.
    label : str or None
        Tag the run was added with.
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
        Log entries so far, by severity.
    logs : list of LogEvent
        Every log entry so far, oldest first; complete once finished.
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
    label: str | None = None
    trnrun_args: list[str] = field(default_factory=list[str])
    status: SimulationStatus | None = None
    status_message: str | None = None
    progress: ProgressEvent | None = None
    config: ConfigEvent | None = None
    setting: dict[str, object] | None = None
    notices: int = 0
    warnings: int = 0
    fatals: int = 0
    logs: list[LogEvent] = field(default_factory=list[LogEvent])
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


# -----------------------------------------------------------------
# Parsers
# -----------------------------------------------------------------
def _parse_timestamp(value: str | None) -> datetime | None:
    """Parse a UTC timestamp, such as ``2026-10-09T14:03:12.345Z``."""
    return None if value is None else datetime.fromisoformat(value)


def parse_run(run: dict[str, Any]) -> SimulationInfo:
    """Parse a run object of a trnrund reply; an event TRNRun has not reported yet becomes None."""
    status = run["trnrunStatus"]
    percent = run["percent"]
    stop = run["stopTime"]
    return SimulationInfo(
        run_id=run["runId"],
        state=SimulationState(run["state"]),
        deck_file=Path(run["deckFile"]),
        label=run["label"],
        trnrun_args=run["trnrunArgs"],
        status=None if status is None else SimulationStatus(status),
        status_message=run["trnrunMessage"],
        progress=None if percent is None else ProgressEvent(run["simTime"], percent, run["elapsedMs"], run["etaMs"]),
        config=None if stop is None else ConfigEvent(run["startTime"], stop, run["timeStep"]),
        setting=run["setting"],
        notices=run["notices"],
        warnings=run["warnings"],
        fatals=run["fatals"],
        logs=[_parse_log(log) for log in run["logs"]],
        succeeded=run["succeeded"],
        exit_code=run["exitCode"],
        error=run["error"],
        submitted_at=_parse_timestamp(run["submittedAt"]),
        started_at=_parse_timestamp(run["startedAt"]),
        finished_at=_parse_timestamp(run["finishedAt"]),
    )


def _parse_log(log: dict[str, Any]) -> LogEvent:
    """Parse a log object of a run object."""
    return LogEvent(
        severity=LogSeverity(log["severity"]),
        time=log["simTime"],
        unit_id=log["unitId"],
        type_id=log["typeId"],
        message_code=log["messageCode"],
        message=log["message"],
        information=log["information"],
    )
