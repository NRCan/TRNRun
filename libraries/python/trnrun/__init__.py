"""Run TRNSYS simulations through trnrund.

``Daemon`` is the thin client: one method per trnrund command, returning
simulations as ``Simulation`` records. ``SimulationManager`` launches many
simulations on one daemon, waits for them as asked, and shows them live in the
terminal; ``add`` returns a ``Simulation`` it keeps current.
"""

from trnrun.daemon import Daemon, DaemonExitedError, RequestError, TrnrunError
from trnrun.display import Display
from trnrun.manager import SimulationManager
from trnrun.simulation import (
    LogEvent,
    LogSeverity,
    Simulation,
    SimulationState,
    SimulationStatus,
    StateName,
    parse_simulation,
)
from trnrun.settings import SimulationSettings

__version__ = "0.9.1"
__all__ = [
    "Daemon",
    "DaemonExitedError",
    "Display",
    "LogEvent",
    "LogSeverity",
    "RequestError",
    "Simulation",
    "SimulationManager",
    "SimulationSettings",
    "SimulationState",
    "SimulationStatus",
    "StateName",
    "TrnrunError",
    "parse_simulation",
]
