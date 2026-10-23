"""Run batches of TRNSYS simulations and follow their progress.

For scripts and notebooks: ``SimulationManager`` starts the daemon, keeps a
``Simulation`` handle per run in sync whenever you call ``wait()`` or
``refresh()``, and shows their progress with a ``ProgressDisplay``, or any
``Display``.

Applications with their own GUI use ``Daemon`` to submit runs and poll
``Daemon.get()`` for each one, as a ``SimulationInfo`` record holding its
``LogEvent`` logs. Those live in ``trnrun.core``; every name either needs is importable
from here.
"""

from trnrun.core import (
    ClosedError,
    ConfigEvent,
    Daemon,
    DaemonExitedError,
    LogEvent,
    LogSeverity,
    ProgressEvent,
    ProtocolError,
    ProtocolVersionError,
    RequestRejectedError,
    SimulationInfo,
    SimulationSettings,
    SimulationState,
    SimulationStatus,
    TrnrunError,
    parse_run,
)
from trnrun.display import Display, ProgressDisplay
from trnrun.manager import SimulationManager
from trnrun.simulation import Simulation

__version__ = "0.8.0"
__all__ = [
    "ClosedError",
    "ConfigEvent",
    "Daemon",
    "DaemonExitedError",
    "Display",
    "LogEvent",
    "LogSeverity",
    "ProgressDisplay",
    "ProgressEvent",
    "ProtocolError",
    "ProtocolVersionError",
    "RequestRejectedError",
    "Simulation",
    "SimulationInfo",
    "SimulationManager",
    "SimulationSettings",
    "SimulationState",
    "SimulationStatus",
    "TrnrunError",
    "parse_run",
]
