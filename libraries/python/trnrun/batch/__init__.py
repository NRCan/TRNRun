"""Launch and follow TRNSYS simulations without writing a polling loop.

For scripts and notebooks: ``SimulationManager`` starts the daemon, keeps a
``Simulation`` handle per run in sync from a background thread, and shows
their progress. ``ProgressDisplay`` needs Rich (``pip install trnrun[display]``)
and is imported only when used. Applications that want their own polling or
database handling should use ``trnrun.Daemon`` instead.
"""

from typing import TYPE_CHECKING

from .manager import Display, SimulationManager
from .simulation import Simulation

if TYPE_CHECKING:
    from .display import ProgressDisplay

__all__ = [
    "Display",
    "ProgressDisplay",
    "Simulation",
    "SimulationManager",
]


def __getattr__(name: str) -> object:
    """Import ``ProgressDisplay``, and with it Rich, only when it is used."""
    if name == "ProgressDisplay":
        from .display import ProgressDisplay

        return ProgressDisplay
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
