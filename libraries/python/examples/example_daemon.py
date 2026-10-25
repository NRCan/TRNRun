"""Run one deck with the thin Daemon client and poll it until it finishes."""

import time
from pathlib import Path

from trnrun import Daemon, SimulationSettings

DECK = Path(__file__).resolve().parents[3] / "decks" / "slow_wo_plot_w_tracking.dck"
SETTINGS = SimulationSettings(trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe", watch_tmp=True)


def main() -> None:
    """Add the deck, print its progress, then print its outcome and release it."""
    with Daemon(workers=1) as daemon:
        sim_id = daemon.add(DECK, SETTINGS)
        while not (sim := daemon.simulation(sim_id)).is_finished:
            print(f"{sim.state:<8} {sim.percent or 0:.0%}")
            time.sleep(1)
        sim = daemon.simulation(sim_id, with_logs=True)
        print(f"{sim.status}: succeeded={sim.succeeded}, {len(sim.logs)} log entries")
        daemon.release(sim_id)


if __name__ == "__main__":
    main()
