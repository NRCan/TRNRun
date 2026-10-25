"""Example: running one simulation with manual progress reporting."""

import shutil
from pathlib import Path

from trnrun import SimulationManager, SimulationSettings

HERE = Path(__file__).resolve().parent
MASTER_DCK = HERE.parents[2] / "decks" / "slow_wo_plot_w_tracking.dck"
SETTINGS = SimulationSettings(watch_tmp=True)

runs = HERE / "runs"
runs.mkdir(exist_ok=True)
deck = Path(shutil.copyfile(MASTER_DCK, runs / MASTER_DCK.name))

with SimulationManager(workers=1, poll_interval=0.1) as manager:
    sim = manager.add(deck, SETTINGS)
    manager.wait(sim)
