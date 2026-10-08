"""Example: a minimal tkinter GUI showing one line per simulation."""

import tkinter as tk
from pathlib import Path

from trnrun import Simulation, SimulationConfig, SimulationManager

__root__ = Path(__file__).resolve().parent

DECKS = [__root__ / "dck" / "example_wo_plot_w_tracking.dck", __root__ / "dck" / "example_wo_plot_wo_tracking.dck"]
CONFIG = SimulationConfig(watch_tmp=True)

root = tk.Tk()
manager = SimulationManager(max_concurrent=2, display=False)  # The window is the display.
labels: dict[Simulation, tk.Label] = {}

for deck in DECKS:
    label = tk.Label(root, anchor="w", width=60)
    label.pack()
    labels[manager.add(deck, CONFIG)] = label


def tick() -> None:
    """Redraw every line from the handles, which the manager keeps current."""
    for simulation, label in labels.items():
        snapshot = simulation.snapshot()
        percent = f"{snapshot.progress.percent:.0%}" if snapshot.progress else ""
        label["text"] = f"{snapshot.deck_path.name}: {snapshot.status or snapshot.state} {percent}"
    root.after(500, tick)


def close() -> None:
    """Stop the daemon, then the window."""
    manager.shutdown()
    root.destroy()


root.protocol("WM_DELETE_WINDOW", close)
tick()
root.mainloop()
