"""Optional script/notebook conveniences built on the core client API."""

from __future__ import annotations

from typing import TYPE_CHECKING

from trnrun.convenience.manager import Display, SimulationManager
from trnrun.convenience.simulation import Simulation

if TYPE_CHECKING:
    from trnrun.convenience.display import ProgressDisplay

__all__ = [
    "Display",
    "ProgressDisplay",
    "Simulation",
    "SimulationManager",
]


def __getattr__(name: str) -> type[ProgressDisplay]:
    """Load the built-in display only when requested."""
    if name == "ProgressDisplay":
        from trnrun.convenience.display import ProgressDisplay

        return ProgressDisplay
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
