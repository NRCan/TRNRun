"""Core client API; automatic polling and displays live in ``trnrun.convenience``."""

from trnrun.client import DaemonClient
from trnrun.config import SimulationConfig
from trnrun.events import SimulationReply, SimulationState, SimulationStatus

__version__ = "0.7.0"

__all__ = [
    "DaemonClient",
    "SimulationConfig",
    "SimulationReply",
    "SimulationState",
    "SimulationStatus",
]
