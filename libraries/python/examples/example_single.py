"""Example: running one simulation with manual progress reporting."""

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1, refresh_interval=0.1) as manager:
    sim = manager.add(r"examples\dck\example_wo_plot_w_tracking.dck", config)
    manager.wait(sim)
