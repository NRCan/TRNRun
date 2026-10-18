"""Drive trnrund and read its database, for applications with their own GUI or polling.

``Daemon`` starts trnrund and submits runs; ``connect`` and ``read_changes``
read what it saved into ``SimulationInfo`` and ``LogEvent`` records. Nothing
here imports the ``SimulationManager`` layer built on top of it.
"""

from trnrun.core.daemon import Daemon
from trnrun.core.database import connect, parse_log, parse_run, read_changes
from trnrun.core.errors import (
    ClosedError,
    DaemonExitedError,
    RequestRejectedError,
    SchemaVersionError,
    SyncError,
    TrnrunError,
)
from trnrun.core.records import (
    Changes,
    ConfigEvent,
    LogEvent,
    LogSeverity,
    ProgressEvent,
    SimulationInfo,
    SimulationState,
    SimulationStatus,
)
from trnrun.core.settings import SimulationSettings

__all__ = [
    "Changes",
    "ClosedError",
    "ConfigEvent",
    "Daemon",
    "DaemonExitedError",
    "LogEvent",
    "LogSeverity",
    "ProgressEvent",
    "RequestRejectedError",
    "SchemaVersionError",
    "SimulationInfo",
    "SimulationSettings",
    "SimulationState",
    "SimulationStatus",
    "SyncError",
    "TrnrunError",
    "connect",
    "parse_log",
    "parse_run",
    "read_changes",
]
