"""Run batches of TRNSYS simulations and follow their progress.

For scripts and notebooks: ``SimulationManager`` starts the daemon, keeps a
``Simulation`` handle per run in sync from a background thread, and shows
their progress with a ``ProgressDisplay``, or any ``Display``.

Applications with their own GUI use ``Daemon`` to submit runs and
``read_changes`` to read what changed into ``SimulationInfo`` and ``LogEvent``
records. Those live in ``trnrun.core``; every name either needs is importable
from here.
"""

from trnrun.core import (
    Changes,
    ClosedError,
    ConfigEvent,
    Daemon,
    DaemonExitedError,
    LogEvent,
    LogSeverity,
    ProgressEvent,
    RequestRejectedError,
    SchemaVersionError,
    SimulationInfo,
    SimulationSettings,
    SimulationState,
    SimulationStatus,
    SyncError,
    TrnrunError,
    connect,
    parse_log,
    parse_run,
    read_changes,
)
from trnrun.display import Display, ProgressDisplay
from trnrun.manager import SimulationManager
from trnrun.simulation import Simulation

__version__ = "0.7.0"
__all__ = [
    "Changes",
    "ClosedError",
    "ConfigEvent",
    "Daemon",
    "DaemonExitedError",
    "Display",
    "LogEvent",
    "LogSeverity",
    "ProgressDisplay",
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
