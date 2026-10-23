"""Drive trnrund and read its runs, for applications with their own GUI or polling.

``Daemon`` starts trnrund, submits runs, and asks for their state, replied as
``SimulationInfo`` records holding their ``LogEvent`` logs. Nothing here imports the
``SimulationManager`` layer built on top of it.
"""

from trnrun.core.daemon import Daemon
from trnrun.core.errors import (
    ClosedError,
    DaemonExitedError,
    ProtocolError,
    ProtocolVersionError,
    RequestRejectedError,
    TrnrunError,
)
from trnrun.core.records import (
    ConfigEvent,
    LogEvent,
    LogSeverity,
    ProgressEvent,
    SimulationInfo,
    SimulationState,
    SimulationStatus,
    parse_run,
)
from trnrun.core.settings import SimulationSettings

__all__ = [
    "ClosedError",
    "ConfigEvent",
    "Daemon",
    "DaemonExitedError",
    "LogEvent",
    "LogSeverity",
    "ProgressEvent",
    "ProtocolError",
    "ProtocolVersionError",
    "RequestRejectedError",
    "SimulationInfo",
    "SimulationSettings",
    "SimulationState",
    "SimulationStatus",
    "TrnrunError",
    "parse_run",
]
