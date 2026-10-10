"""Example: a minimal tkinter GUI showing one line per simulation.

Install with ``pip install trnrun``; this custom GUI does not require Rich.
"""

import tkinter as tk
from pathlib import Path

from trnrun import SimulationConfig, SimulationState
from trnrun.convenience import Simulation, SimulationManager

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
    for simulation, label in list(labels.items()):
        info = simulation.info  # One read, so the fields below agree.
        status = info.status.status if info.status else info.state
        percent = f"{info.progress.percent:.0%}" if info.progress else ""
        label["text"] = f"{simulation.deck_path.name}: {status} {percent}"
        if info.state is SimulationState.FINISHED:
            del labels[simulation]  # Final: drawn once, never again.
    root.after(500, tick)


def close() -> None:
    """Stop the daemon, then the window."""
    manager.shutdown()
    root.destroy()


root.protocol("WM_DELETE_WINDOW", close)
tick()
root.mainloop()
