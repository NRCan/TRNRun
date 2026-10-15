"""The TRNRun events trnrund saves, as typed values.

They mirror the events of trnrund's ``events.nim``. ``LogEvent`` also carries
the ``log_id`` and ``run_id`` of its database row.
"""

from dataclasses import dataclass
from enum import StrEnum


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
class SettingEvent:
    """The settings TRNRun reported applying, with its defaults filled in.

    Each field is the ``SimulationSettings`` field of the same name, which
    documents it; durations are in milliseconds.
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
