"""Typed views of what trnrund saves: one record per run, one per log entry.

The daemon flattens the latest TRNRun event of each kind into its run's row.
``parse_run`` groups those columns back into the events they came from, and
``parse_log`` reads one ``logs`` row. ``Database`` returns these records, and
``trnrun.batch`` keeps them on its handles.
"""

# pyright: reportAny=false

import json
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from pathlib import Path


# -----------------------------------------------------------------
# Events
# -----------------------------------------------------------------
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


@dataclass(frozen=True)
class StatusEvent:
    """The run's latest TRNRun status.

    Attributes
    ----------
    status : SimulationStatus
        State reported by TRNRun.
    message : str
        Optional outcome or failure detail reported by TRNRun.
    """

    status: SimulationStatus
    message: str = ""


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
    """The simulation's time bounds and step, in simulated hours.

    Attributes
    ----------
    start : float
        Simulation start time.
    stop : float
        Simulation stop time.
    step : float
        Simulation time step.
    """

    start: float
    stop: float
    step: float


@dataclass(frozen=True)
class LogEvent:
    """One severity-tagged TRNSYS log entry.

    Only ``severity`` and ``time`` are guaranteed; the remaining fields
    depend on what TRNSYS attaches to the message.

    Attributes
    ----------
    log_id : int
        Position of the entry among every run's logs; grows with each entry.
    run_id : int
        Run the entry belongs to.
    severity : str
        Severity tag: ``"Notice"``, ``"Warning"`` or ``"Fatal"``.
    time : float
        Simulation time at which the message was produced.
    unit_id : int or None
        Unit that emitted the message.
    type_id : int or None
        Type of the unit that emitted the message.
    message_code : int or None
        Numeric code identifying the message.
    message : str or None
        Human-readable message text.
    information : str or None
        Additional detail attached to the message.
    """

    log_id: int
    run_id: int
    severity: str
    time: float
    unit_id: int | None = None
    type_id: int | None = None
    message_code: int | None = None
    message: str | None = None
    information: str | None = None


# -----------------------------------------------------------------
# Daemon State
# -----------------------------------------------------------------
class SimulationState(StrEnum):
    """Daemon-owned lifecycle, independent of the runner-reported status.

    ``QUEUED → RUNNING → FINISHED``. A run that never starts, such as one
    cancelled while queued or whose TRNRun cannot launch, goes straight to
    ``FINISHED``.
    """

    QUEUED = "QUEUED"
    RUNNING = "RUNNING"
    FINISHED = "FINISHED"


@dataclass(frozen=True)
class SimulationInfo:
    """A run's state at one moment: its row in the daemon's database.

    Log entries are kept separately; see ``Database.get_logs``.

    Attributes
    ----------
    run_id : int
        Number the daemon assigned the run; never reused in its database.
    state : SimulationState
        Daemon lifecycle state.
    session_id : int
        The daemon start that added the run.
    label : str or None
        Tag the run was added with.
    revision : int
        Revision of the run's latest save.
    deck_file : Path or None
        Absolute deck path.
    trnrun_args : list of str
        TRNRun options the run was added with.
    status, progress, config
        Latest event of each kind, or None before TRNRun reports one.
    setting : dict or None
        Settings TRNRun reported applying, keyed by TRNRun's camelCase names,
        or None before it reports them.
    notices, warnings, fatals : int
        Number of log entries saved so far, by severity.
    succeeded : bool
        Whether the run finished with ``DONE``, exit code 0, and no error;
        False until it finishes.
    exit_code : int or None
        TRNRun exit code, or None until it exits or if it never launched.
    error : str
        Execution error reported by the daemon, independent of TRNRun status.
    submitted_at, started_at, finished_at : datetime or None
        UTC times the run was added, TRNRun started, and the run finished;
        None until they happen, and ``started_at`` stays None for a run that
        never started.
    """

    run_id: int
    state: SimulationState
    session_id: int = 0
    label: str | None = None
    revision: int = 0
    deck_file: Path | None = None
    trnrun_args: list[str] = field(default_factory=list[str])
    status: StatusEvent | None = None
    progress: ProgressEvent | None = None
    config: ConfigEvent | None = None
    setting: dict[str, object] | None = None
    notices: int = 0
    warnings: int = 0
    fatals: int = 0
    succeeded: bool = False
    exit_code: int | None = None
    error: str = ""
    submitted_at: datetime | None = None
    started_at: datetime | None = None
    finished_at: datetime | None = None

    @property
    def is_finished(self) -> bool:
        """Return whether the daemon finished the run; its logs are then complete."""
        return self.state is SimulationState.FINISHED


@dataclass(frozen=True)
class Changes:
    """What one ``Database.poll()`` read: the runs that changed and the new logs.

    Attributes
    ----------
    runs : list of SimulationInfo
        Latest snapshot of each run saved since the previous poll, in the
        order they last changed. Intermediate states between polls are not
        kept.
    logs : list of LogEvent
        Log entries saved since the previous poll, oldest first.
    """

    runs: list[SimulationInfo] = field(default_factory=list[SimulationInfo])
    logs: list[LogEvent] = field(default_factory=list[LogEvent])

    def __bool__(self) -> bool:
        """Return whether anything changed."""
        return bool(self.runs or self.logs)


# -----------------------------------------------------------------
# Row Parsers
# -----------------------------------------------------------------
def _timestamp(value: str | None) -> datetime | None:
    """Parse a saved UTC timestamp, such as ``2026-10-09T14:03:12.345Z``."""
    return None if value is None else datetime.fromisoformat(value)


def parse_run(row: sqlite3.Row) -> SimulationInfo:
    """Parse a ``runs`` row; an event TRNRun has not reported yet becomes None."""
    status = row["trnrun_status"]
    percent = row["percent"]
    stop = row["stop_time"]
    setting = row["setting"]
    return SimulationInfo(
        run_id=row["run_id"],
        state=SimulationState(row["state"]),
        session_id=row["session_id"],
        label=row["label"],
        revision=row["revision"],
        deck_file=Path(row["deck_file"]),
        trnrun_args=json.loads(row["trnrun_args"]),
        status=None if status is None else StatusEvent(SimulationStatus(status), row["trnrun_message"] or ""),
        progress=None if percent is None else ProgressEvent(row["sim_time"], percent, row["elapsed_ms"], row["eta_ms"]),
        config=None if stop is None else ConfigEvent(row["start_time"], stop, row["time_step"]),
        setting=None if setting is None else json.loads(setting),
        notices=row["notices"],
        warnings=row["warnings"],
        fatals=row["fatals"],
        succeeded=bool(row["succeeded"]),
        exit_code=row["exit_code"],
        error=row["error"] or "",
        submitted_at=_timestamp(row["submitted_at"]),
        started_at=_timestamp(row["started_at"]),
        finished_at=_timestamp(row["finished_at"]),
    )


def parse_log(row: sqlite3.Row) -> LogEvent:
    """Parse a ``logs`` row."""
    return LogEvent(
        log_id=row["log_id"],
        run_id=row["run_id"],
        severity=row["severity"],
        time=row["sim_time"],
        unit_id=row["unit_id"],
        type_id=row["type_id"],
        message_code=row["message_code"],
        message=row["message"],
        information=row["information"],
    )
