"""Example: running one simulation with the built-in progress display.

Install with ``pip install "trnrun[display]"`` for the built-in Rich display.
"""

from pathlib import Path

from trnrun import SimulationConfig
from trnrun.convenience import SimulationManager

__root__ = Path(__file__).resolve().parent

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1, poll_interval=0.1) as manager:
    sim = manager.add(__root__ / "dck" / "example_wo_plot_w_tracking.dck", config)
    sim.wait()
