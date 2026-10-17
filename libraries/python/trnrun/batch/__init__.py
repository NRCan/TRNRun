"""Launch and follow TRNSYS simulations without writing a polling loop.

For scripts and notebooks: ``SimulationManager`` starts the daemon, keeps a
``Simulation`` handle per run in sync from a background thread, and shows
their progress with a ``ProgressDisplay``, or any ``Display``. Both are also
importable from ``trnrun``. Applications that want their own polling or
database handling should use ``trnrun.Daemon`` instead.
"""

from .display import Display, ProgressDisplay
from .manager import SimulationManager
from .simulation import Simulation

__all__ = [
    "Display",
    "ProgressDisplay",
    "Simulation",
    "SimulationManager",
]
