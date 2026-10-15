"""Example: a developer-owned tkinter GUI using only the thin core API.

It does not use ``trnrun.batch``: the application owns its widgets and timer,
and each tick reads what changed with the non-blocking ``Daemon.poll()``. For
a GUI that would rather let a background thread keep handles up to date, see
``SimulationManager(display=False)`` in the README.
"""

import tkinter as tk
from pathlib import Path

from trnrun import Daemon, SimulationSettings

__root__ = Path(__file__).resolve().parent

DECKS = [__root__ / "dck" / "example_wo_plot_w_tracking.dck", __root__ / "dck" / "example_wo_plot_wo_tracking.dck"]
SETTINGS = SimulationSettings(watch_tmp=True)
POLL_MS = 500


def main() -> None:
    """Submit decks and draw database changes on the UI thread."""
    with Daemon(max_concurrent=2) as daemon:
        root = tk.Tk()
        root.title("TRNRun - custom GUI")
        labels: dict[int, tk.Label] = {}
        decks: dict[int, Path] = {}

        for deck in DECKS:
            run_id = daemon.add(deck, SETTINGS)
            label = tk.Label(root, anchor="w", width=80, text=f"{deck.name}: queued")
            label.pack()
            labels[run_id] = label
            decks[run_id] = deck
        pending = set(decks)

        message = tk.Label(root, anchor="w", width=80)
        message.pack()

        def tick() -> None:
            """Read changed runs and redraw only their rows."""
            try:
                changes = daemon.poll()
            except RuntimeError as error:  # trnrund exited, and everything it saved was read.
                message["text"] = str(error)
                return
            for run in changes.runs:
                status = run.status.status if run.status is not None else run.state
                percent = "" if run.progress is None else f"{run.progress.percent:.0%}"
                if run.is_finished:
                    reason = run.error or (run.status.message if run.status is not None else "") or status
                    status = "Succeeded" if run.succeeded else f"Failed: {reason}"
                    pending.discard(run.run_id)
                labels[run.run_id]["text"] = f"{decks[run.run_id].name}: {status} {percent}"

            if pending:
                root.after(POLL_MS, tick)
            else:
                message["text"] = "All runs finished."

        tick()
        # Closing the window ends mainloop; leaving the with block then interrupts unfinished runs.
        root.mainloop()


if __name__ == "__main__":
    main()
