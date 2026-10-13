"""Example: a developer-owned tkinter GUI using only the thin core API.

It does not use ``trnrun.batch``: the application owns its run IDs, widgets,
and polling timer. For a GUI that would rather let a background thread keep
handles up to date, see ``SimulationManager(display=False)`` in the README.
"""

import tkinter as tk
from pathlib import Path
from tempfile import TemporaryDirectory

from trnrun import Daemon, SimulationConfig

__root__ = Path(__file__).resolve().parent

DECKS = [__root__ / "dck" / "example_wo_plot_w_tracking.dck", __root__ / "dck" / "example_wo_plot_wo_tracking.dck"]
CONFIG = SimulationConfig(watch_tmp=True)
POLL_MS = 500


def daemon_error(daemon: Daemon) -> str | None:
    """Return why trnrund exited unexpectedly, or None while it runs."""
    try:
        daemon.check()
    except RuntimeError as error:
        return str(error)
    return None


def main() -> None:
    """Submit decks and draw database changes on the UI thread."""
    # A fresh database per launch, so the run IDs below are always new.
    with (
        TemporaryDirectory(prefix="trnrun-gui-", ignore_cleanup_errors=True) as database_dir,
        Daemon(Path(database_dir) / "runs.sqlite3", max_concurrent=2) as daemon,
    ):
        root = tk.Tk()
        root.title("TRNRun - custom GUI")
        labels: dict[str, tk.Label] = {}
        runs = {str(index): deck for index, deck in enumerate(DECKS, start=1)}
        pending = set(runs)
        # Captured before submitting, so every change to these runs comes after it.
        revision = daemon.database.get_latest_revision()

        for run_id, deck in runs.items():
            label = tk.Label(root, anchor="w", width=80, text=f"{deck.name}: queued")
            label.pack()
            labels[run_id] = label
            daemon.add(run_id, deck, CONFIG)

        message = tk.Label(root, anchor="w", width=80)
        message.pack()

        def tick() -> None:
            """Read changed runs and redraw only their rows."""
            nonlocal revision
            # Checked before reading, so a daemon found exited saved everything read below.
            error = daemon_error(daemon)
            for row in daemon.database.get_changed_runs(revision):
                revision = row["revision"]
                run_id = row["run_id"]
                status = row["trnrun_status"] or row["state"]
                percent = "" if row["percent"] is None else f"{row['percent']:.0%}"
                if row["state"] == "FINISHED":
                    reason = row["error"] or row["trnrun_message"] or status
                    status = "Succeeded" if row["succeeded"] else f"Failed: {reason}"
                    pending.discard(run_id)
                labels[run_id]["text"] = f"{runs[run_id].name}: {status} {percent}"

            if error is not None:
                message["text"] = error
            elif pending:
                root.after(POLL_MS, tick)
            else:
                message["text"] = "All runs finished."

        tick()
        # Closing the window ends mainloop; leaving the with block then cancels unfinished runs.
        root.mainloop()


if __name__ == "__main__":
    main()
