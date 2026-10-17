"""Typed records of trnrund's ``runs`` and ``logs`` rows, and their parsers."""

# pyright: reportAny=false

import json
import sqlite3
from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from pathlib import Path

from .events import ConfigEvent, LogEvent, LogSeverity, ProgressEvent, SimulationStatus


# -----------------------------------------------------------------
# Daemon State
# -----------------------------------------------------------------
class SimulationState(StrEnum):
    """Daemon lifecycle, ``QUEUED → RUNNING → FINISHED``; a run that never starts goes straight to ``FINISHED``."""

    QUEUED = "QUEUED"
    RUNNING = "RUNNING"
    FINISHED = "FINISHED"


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


# -----------------------------------------------------------------
# Row Parsers
# -----------------------------------------------------------------
def _parse_timestamp(value: str | None) -> datetime | None:
    """Parse a saved UTC timestamp, such as ``2026-10-09T14:03:12.345Z``."""
    return None if value is None else datetime.fromisoformat(value)


def parse_run(row: sqlite3.Row) -> SimulationInfo:
    """Parse a ``SELECT *`` row of ``runs``; an event TRNRun has not reported yet becomes None."""
    status = row["trnrun_status"]
    percent = row["percent"]
    stop = row["stop_time"]
    setting = row["setting"]
    succeeded = row["succeeded"]
    return SimulationInfo(
        run_id=row["run_id"],
        state=SimulationState(row["state"]),
        deck_file=Path(row["deck_file"]),
        session_id=row["session_id"],
        label=row["label"],
        revision=row["revision"],
        trnrun_args=json.loads(row["trnrun_args"]),
        status=None if status is None else SimulationStatus(status),
        status_message=row["trnrun_message"],
        progress=None if percent is None else ProgressEvent(row["sim_time"], percent, row["elapsed_ms"], row["eta_ms"]),
        config=None if stop is None else ConfigEvent(row["start_time"], stop, row["time_step"]),
        setting=None if setting is None else json.loads(setting),
        notices=row["notices"],
        warnings=row["warnings"],
        fatals=row["fatals"],
        succeeded=None if succeeded is None else bool(succeeded),
        exit_code=row["exit_code"],
        error=row["error"],
        submitted_at=_parse_timestamp(row["submitted_at"]),
        started_at=_parse_timestamp(row["started_at"]),
        finished_at=_parse_timestamp(row["finished_at"]),
    )


def parse_log(row: sqlite3.Row) -> LogEvent:
    """Parse a ``SELECT *`` row of ``logs``."""
    return LogEvent(
        log_id=row["log_id"],
        run_id=row["run_id"],
        severity=LogSeverity(row["severity"]),
        time=row["sim_time"],
        unit_id=row["unit_id"],
        type_id=row["type_id"],
        message_code=row["message_code"],
        message=row["message"],
        information=row["information"],
    )
