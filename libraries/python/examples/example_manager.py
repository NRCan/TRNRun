"""Run copies of a deck, many at a time, with live progress in the terminal."""

import shutil
from pathlib import Path

from trnrun import SimulationManager, SimulationSettings

HERE = Path(__file__).resolve().parent
MASTER_DCK = HERE.parents[2] / "decks" / "slow_wo_plot_w_tracking.dck"
SETTINGS = SimulationSettings(trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe", watch_tmp=True)

runs = HERE / "runs"
runs.mkdir(exist_ok=True)
decks = [Path(shutil.copyfile(MASTER_DCK, runs / f"{MASTER_DCK.stem}_{i:03d}.dck")) for i in range(1, 11)]

with SimulationManager(workers=5, poll_interval=0.1) as manager:
    for deck in decks:
        _ = manager.add(deck, SETTINGS, wait_for="RUNNING")
    manager.wait()

failed = [sim for sim in manager.simulations.values() if not sim.succeeded]
print(f"{len(decks) - len(failed)}/{len(decks)} succeeded")
for sim in failed:
    print(f"  [{sim.sim_id}] {sim.deck_file.name}: {sim.status} {sim.error or sim.status_message}")
