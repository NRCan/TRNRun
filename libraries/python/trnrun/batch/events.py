"""Typed views of what trnrund saves: one row per run, one row per log entry.

The daemon flattens the latest TRNRun event of each kind into its run's row.
``parse_run`` groups those columns back into the events they came from, and
``parse_log`` reads one ``logs`` row; both take the ``sqlite3.Row`` objects
that ``TrnRunDatabase`` returns.
"""

# pyright: reportAny=false

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from typing import Any


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
class SettingEvent:
    """The runner settings TRNRun applied to the run.

    Field names are the ``SimulationConfig`` ones, converted from TRNRun's
    camelCase.
    """

    trnexe_path: str
    gui_visibility: str
    wait_for_gui: bool
    wait_for_lst: bool
    wait_for_tmp: bool
    detect_timeout_ms: int
    extra_delay_ms: int
    watch_log: bool
    watch_tmp: bool
    watch_timeout_ms: int
    stall_timeout_ms: int
    poll_ms: int
    clean_on_success: bool
    kill_on_timeout: bool
    kill_on_stall: bool
    severity: str
    write_events: bool


@dataclass(frozen=True)
class LogEvent:
    """One severity-tagged TRNSYS log entry.

    Only ``severity`` and ``time`` are guaranteed; the remaining fields
    depend on what TRNSYS attaches to the message.

    Attributes
    ----------
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

    ``QUEUED → ACCEPTED → RUNNING → FINISHED``. A run that never starts, such
    as one cancelled while queued, goes straight to ``FINISHED``.
    """

    QUEUED = "QUEUED"
    ACCEPTED = "ACCEPTED"
    RUNNING = "RUNNING"
    FINISHED = "FINISHED"


@dataclass(frozen=True)
class SimulationInfo:
    """A simulation's state at one moment: its row in the daemon's database.

    Log entries are kept separately, by ``Simulation.logs``.

    Attributes
    ----------
    state : SimulationState
        Daemon lifecycle state.
    status, progress, config, setting
        Latest event of each kind, or None before TRNRun reports one.
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

    state: SimulationState
    status: StatusEvent | None = None
    progress: ProgressEvent | None = None
    config: ConfigEvent | None = None
    setting: SettingEvent | None = None
    notices: int = 0
    warnings: int = 0
    fatals: int = 0
    succeeded: bool = False
    exit_code: int | None = None
    error: str = ""
    submitted_at: datetime | None = None
    started_at: datetime | None = None
    finished_at: datetime | None = None


# -----------------------------------------------------------------
# Row Parsers
# -----------------------------------------------------------------
def _timestamp(value: str | None) -> datetime | None:
    """Parse a saved UTC timestamp, such as ``2026-10-09T14:03:12.345Z``."""
    return None if value is None else datetime.fromisoformat(value)


def parse_setting(data: Any) -> SettingEvent:
    """Parse a decoded ``setting`` column; extra keys such as ``timestamp`` are ignored."""
    return SettingEvent(
        trnexe_path=data["trnexePath"],
        gui_visibility=data["guiVisibility"],
        wait_for_gui=data["waitForGui"],
        wait_for_lst=data["waitForLst"],
        wait_for_tmp=data["waitForTmp"],
        detect_timeout_ms=data["detectTimeoutMs"],
        extra_delay_ms=data["extraDelayMs"],
        watch_log=data["watchLog"],
        watch_tmp=data["watchTmp"],
        watch_timeout_ms=data["watchTimeoutMs"],
        stall_timeout_ms=data["stallTimeoutMs"],
        poll_ms=data["pollMs"],
        clean_on_success=data["cleanOnSuccess"],
        kill_on_timeout=data["killOnTimeout"],
        kill_on_stall=data["killOnStall"],
        severity=data["severity"],
        write_events=data["writeEvents"],
    )


def parse_run(row: sqlite3.Row) -> SimulationInfo:
    """Parse a ``runs`` row; an event TRNRun has not reported yet becomes None."""
    status = row["trnrun_status"]
    percent = row["percent"]
    stop = row["stop_time"]
    setting = row["setting"]
    return SimulationInfo(
        state=SimulationState(row["state"]),
        status=None if status is None else StatusEvent(SimulationStatus(status), row["trnrun_message"] or ""),
        progress=None if percent is None else ProgressEvent(row["sim_time"], percent, row["elapsed_ms"], row["eta_ms"]),
        config=None if stop is None else ConfigEvent(row["start_time"], stop, row["time_step"]),
        setting=None if setting is None else parse_setting(json.loads(setting)),
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
        severity=row["severity"],
        time=row["sim_time"],
        unit_id=row["unit_id"],
        type_id=row["type_id"],
        message_code=row["message_code"],
        message=row["message"],
        information=row["information"],
    )
