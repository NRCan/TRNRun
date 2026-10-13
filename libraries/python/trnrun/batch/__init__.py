"""Launch and follow TRNSYS simulations without writing a polling loop.

For scripts and notebooks: ``SimulationManager`` starts the daemon, numbers
the runs, keeps a ``Simulation`` handle per run in sync from a background
thread, and shows their progress. Applications that want their own polling,
run IDs, or database should use ``trnrun.Daemon`` instead.
"""

from .display import Display, ProgressDisplay
from .events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SettingEvent,
    SimulationInfo,
    SimulationState,
    SimulationStatus,
    StatusEvent,
)
from .manager import SimulationManager
from .simulation import Simulation

__all__ = [
    "ConfigEvent",
    "Display",
    "LogEvent",
    "ProgressDisplay",
    "ProgressEvent",
    "SettingEvent",
    "Simulation",
    "SimulationInfo",
    "SimulationManager",
    "SimulationState",
    "SimulationStatus",
    "StatusEvent",
]
