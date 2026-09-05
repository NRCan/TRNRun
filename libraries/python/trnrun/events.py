"""Typed runner events and daemon simulation state, and their parsers.

The daemon folds each simulation's TRNRun events into one state object, which
nests the latest event of each kind without its ``kind`` tag or timestamp.
``parse_simulation_update`` and ``parse_log`` decode its replies.
"""

# pyright: reportAny=false

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
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
    """A STATUS event reporting the run's current state.

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
    """A PROGRESS event reporting run completion and timing.

    Attributes
    ----------
    time : float
        Current simulation time.
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
    """A CONFIG event reporting simulation time bounds and step.

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
    """A SETTING event reporting the configured runner settings.

    Wire-protocol field names are converted from camelCase to snake_case.
    Protocol metadata such as ``kind`` and ``seq`` is not retained.
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
    """A LOG event carrying a severity-tagged message.

    Only ``severity`` is guaranteed; the remaining
    fields depend on what TRNRun attaches to the message.

    Attributes
    ----------
    severity : str
        Severity tag: ``"Notice"``, ``"Warning"`` or ``"Fatal"``.
    time : float or None
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
    time: float | None = None
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

    ``QUEUED → ACCEPTED → RUNNING → FINISHED``. A run whose runner fails to
    launch goes from ``ACCEPTED`` to ``FINISHED``.
    """

    QUEUED = "QUEUED"
    ACCEPTED = "ACCEPTED"
    RUNNING = "RUNNING"
    FINISHED = "FINISHED"


@dataclass(frozen=True)
class SimulationUpdate:
    """Daemon state for one simulation: its ``simulation`` reply object.

    Logs are not part of it; the daemon sends them separately.

    Attributes
    ----------
    state : SimulationState
        Daemon lifecycle state.
    exit_code : int or None
        Runner exit code, or None until it exits or if it never launched.
    error : str
        Execution error reported by the daemon, independent of runner status.
    succeeded : bool
        Whether the run finished with ``DONE``, exit code 0, and no error.
    setting, status, config, progress
        Latest event of each kind, or None before the runner reports one.
    notices, warnings, fatals
        Number of log entries the daemon holds, by severity.
    """

    state: SimulationState
    exit_code: int | None = None
    error: str = ""
    succeeded: bool = False
    setting: SettingEvent | None = None
    status: StatusEvent | None = None
    config: ConfigEvent | None = None
    progress: ProgressEvent | None = None
    notices: int = 0
    warnings: int = 0
    fatals: int = 0

    @property
    def log_count(self) -> int:
        """Return how many log entries the daemon holds."""
        return self.notices + self.warnings + self.fatals


# -----------------------------------------------------------------
# Daemon Replies
# -----------------------------------------------------------------
def _optional[T](parse: Callable[[Any], T], data: Any) -> T | None:
    """Parse a nullable nested object."""
    return None if data is None else parse(data)


def _parse_status(data: Any) -> StatusEvent:
    """Parse a nested STATUS event."""
    return StatusEvent(
        SimulationStatus(data["status"]),
        data["message"],
    )


def _parse_progress(data: Any) -> ProgressEvent:
    """Parse a nested PROGRESS event."""
    return ProgressEvent(
        data["time"],
        data["percent"],
        data["elapsedMs"],
        data["etaMs"],
    )


def _parse_config(data: Any) -> ConfigEvent:
    """Parse a nested CONFIG event."""
    return ConfigEvent(
        data["start"],
        data["stop"],
        data["step"],
    )


def _parse_setting(data: Any) -> SettingEvent:
    """Parse a nested SETTING event."""
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


def parse_log(data: Any) -> LogEvent:
    """Parse one log entry of a daemon reply."""
    return LogEvent(
        severity=data["severity"],
        time=data["time"],
        unit_id=data["unitId"],
        type_id=data["typeId"],
        message_code=data["messageCode"],
        message=data["message"],
        information=data["information"],
    )


def parse_simulation_update(data: Any) -> SimulationUpdate:
    """Parse one simulation object from a daemon reply, ignoring its inputs."""
    return SimulationUpdate(
        state=SimulationState(data["state"]),
        exit_code=data["exitCode"],
        error=data["error"],
        succeeded=data["succeeded"],
        setting=_optional(_parse_setting, data["setting"]),
        status=_optional(_parse_status, data["status"]),
        config=_optional(_parse_config, data["config"]),
        progress=_optional(_parse_progress, data["progress"]),
        notices=data["notices"],
        warnings=data["warnings"],
        fatals=data["fatals"],
    )
