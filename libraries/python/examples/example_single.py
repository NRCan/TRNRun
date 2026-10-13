"""Example: running one simulation with the built-in progress display.

Install with ``pip install trnrun``.
"""

from pathlib import Path

from trnrun import SimulationConfig
from trnrun.batch import SimulationManager

__root__ = Path(__file__).resolve().parent

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1, poll_interval=0.1) as manager:
    sim = manager.add(__root__ / "dck" / "example_wo_plot_w_tracking.dck", config)
    manager.wait(sim)

print(f"{sim.deck_path.name}: {sim.status}, succeeded={sim.succeeded}, warnings={sim.warnings}, fatals={sim.fatals}")
