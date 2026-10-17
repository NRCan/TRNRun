"""Run batches of TRNSYS simulations and follow their progress.

``SimulationManager`` runs decks and shows their progress. Applications with
their own GUI use ``Daemon`` to submit runs and ``read_changes`` to read what
changed into ``SimulationInfo`` and ``LogEvent`` records; every name they need
is importable from here.
"""

from .batch import Simulation, SimulationManager
from .daemon import Daemon
from .database import connect, read_changes
from .errors import (
    ClosedError,
    DaemonExitedError,
    RequestRejectedError,
    SchemaVersionError,
    SyncError,
    TrnrunError,
)
from .events import ConfigEvent, LogEvent, LogSeverity, ProgressEvent, SimulationStatus
from .runs import Changes, SimulationInfo, SimulationState, parse_log, parse_run
from .settings import SimulationSettings

__version__ = "0.7.0"
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
    "Simulation",
    "SimulationInfo",
    "SimulationManager",
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
