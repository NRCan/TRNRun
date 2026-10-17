"""The TRNRun events trnrund saves, as typed values, mirroring trnrund's ``events.nim``.

``STATUS`` and ``SETTING`` have no record: they are fields of ``SimulationInfo``.
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


class LogSeverity(StrEnum):
    """Severity of a TRNSYS log entry."""

    NOTICE = "Notice"
    WARNING = "Warning"
    FATAL = "Fatal"


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
