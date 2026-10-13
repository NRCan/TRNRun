"""Typed runner events and the simulation state pulled from the daemon's database.

The daemon saves the latest event of each kind in a run's row, without its
``kind`` tag or timestamp; ``trnrun.database`` reads them back. The ``SETTING``
event is saved as JSON, decoded by ``parse_setting``.
"""

# pyright: reportAny=false

from __future__ import annotations

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
    launch goes from ``ACCEPTED`` to ``FINISHED``; one the daemon stops
    tracking first, when it shuts down or exits, finishes as cancelled from
    whatever state it reached.
    """

    QUEUED = "QUEUED"
    ACCEPTED = "ACCEPTED"
    RUNNING = "RUNNING"
    FINISHED = "FINISHED"


@dataclass(frozen=True)
class SimulationReply:
    """A simulation's state at one moment: its row in the daemon's database.

    ``RunDatabase.get()`` reads the current one; ``RunDatabase.pull()`` returns
    changed snapshots. Log entries are read separately with ``RunDatabase.logs()``.

    Attributes
    ----------
    state : SimulationState
        Daemon lifecycle state.
    exit_code : int or None
        Runner exit code, or None until it exits or if it never launched.
    error : str
        Execution error reported by the daemon, independent of runner status.
    setting, status, config, progress
        Latest event of each kind, or None before the runner reports one.
    notices, warnings, fatals
        Number of log entries the daemon saved so far, by severity.
    succeeded : bool
        Whether the run finished with ``DONE``, exit code 0, and no error.
    """

    state: SimulationState
    exit_code: int | None = None
    error: str = ""
    setting: SettingEvent | None = None
    status: StatusEvent | None = None
    config: ConfigEvent | None = None
    progress: ProgressEvent | None = None
    notices: int = 0
    warnings: int = 0
    fatals: int = 0
    succeeded: bool = False


# -----------------------------------------------------------------
# Event Parsers
# -----------------------------------------------------------------
def parse_setting(data: Any) -> SettingEvent:
    """Parse a saved SETTING event."""
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
