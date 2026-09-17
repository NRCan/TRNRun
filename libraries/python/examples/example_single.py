"""Example: running one simulation with manual progress reporting."""

from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

__root__ = Path(__file__).resolve().parent

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1, refresh_interval=0.1) as manager:
    sim = manager.add(__root__ / "dck" / "example_wo_plot_w_tracking.dck", config)
    manager.wait(sim)
