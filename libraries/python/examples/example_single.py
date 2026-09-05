"""Example: running one simulation with the built-in progress display."""

from pathlib import Path

from trnrun import ProgressDisplay, SimulationConfig, SimulationManager

__root__ = Path(__file__).resolve().parent

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1) as manager:
    _ = ProgressDisplay(manager, refresh_interval=0.1)
    sim = manager.add(__root__ / "dck" / "example_wo_plot_w_tracking.dck", config)
    manager.wait(sim)
