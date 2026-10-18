"""Example: a developer-owned tkinter dashboard using only the thin core API.

Like ``example_manager.py``, it copies one master deck ``SIM_COUNT`` times and
runs every copy, but follows them in a window: a live table of runs, overall
progress, the selected run's details, and a log of every TRNSYS message. Decks
can be added and runs cancelled while the batch runs.

It does not use ``SimulationManager``: the application owns its widgets, its
timer, and its database connection. Each tick asks ``Daemon.wait_for_changes``
without blocking whether anything was saved, and reads it with
``read_changes``. For a GUI that would rather let a background thread keep
handles up to date, see ``SimulationManager(display=False)`` in the README.
"""

from __future__ import annotations

import shutil
import sqlite3
import tkinter as tk
from contextlib import closing
from datetime import UTC, datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Literal

from trnrun import (
    ClosedError,
    Daemon,
    DaemonExitedError,
    LogEvent,
    LogSeverity,
    SimulationInfo,
    SimulationSettings,
    SimulationState,
    SimulationStatus,
    TrnrunError,
    read_changes,
)

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
__root__ = Path(__file__).resolve().parent

TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")
MASTER_DCK = __root__ / "dck" / "example_wo_plot_w_tracking.dck"
DCK_FOLDER = __root__ / "runs"

SIM_COUNT = 10
MAX_CONCURRENT = 5
POLL_MS = 200

SETTINGS = SimulationSettings(trnexe_path=TRNEXE_PATH, watch_tmp=True, watch_log=True)

# Table columns: heading, width, anchor.
COLUMNS: dict[str, tuple[str, int, Literal["w", "center", "e"]]] = {
    "id": ("ID", 45, "center"),
    "deck": ("Deck", 260, "w"),
    "state": ("State", 80, "center"),
    "status": ("TRNRun status", 100, "center"),
    "progress": ("Progress", 190, "w"),
    "time": ("Simulated", 140, "e"),
    "elapsed": ("Elapsed", 75, "center"),
    "eta": ("ETA", 75, "center"),
    "logs": ("Logs", 120, "center"),
}
OUTCOME_COLORS = {
    "queued": "#6b7280",
    "running": "#1d4ed8",
    "succeeded": "#15803d",
    "cancelled": "#b45309",
    "failed": "#b91c1c",
}
SEVERITY_COLORS = {LogSeverity.NOTICE: "#374151", LogSeverity.WARNING: "#b45309", LogSeverity.FATAL: "#b91c1c"}


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def copy_dck(src: Path | str, dst_dir: Path | str, n: int) -> list[Path]:
    """Copy ``src`` into ``dst_dir`` ``n`` times with a zero-padded suffix."""
    src = Path(src)
    dst_dir = Path(dst_dir)
    _ = dst_dir.mkdir(parents=True, exist_ok=True)

    dst_files: list[Path] = []
    for i in range(1, n + 1):
        dst = dst_dir / f"{src.stem}_{i:03d}{src.suffix}"
        _ = shutil.copyfile(src, dst)
        dst_files.append(dst)
    return dst_files


def format_duration(ms: float | None) -> str:
    """Format milliseconds as ``HH:MM:SS``; blank when unknown."""
    if ms is None:
        return ""
    seconds = int(ms // 1000)
    return f"{seconds // 3600:02d}:{seconds // 60 % 60:02d}:{seconds % 60:02d}"


def format_bar(fraction: float, width: int = 16) -> str:
    """Draw a text progress bar with its percentage, such as ``████░░░░ 50%``."""
    fraction = max(0.0, min(fraction, 1.0))
    filled = round(fraction * width)
    return f"{'█' * filled}{'░' * (width - filled)} {fraction:4.0%}"


def format_timestamp(value: datetime | None) -> str:
    """Format a UTC timestamp in local time; blank when it has not happened."""
    return "" if value is None else value.astimezone().strftime("%Y-%m-%d %H:%M:%S")


def outcome(run: SimulationInfo) -> str:
    """Return the run's row tag: queued, running, succeeded, cancelled or failed."""
    if not run.is_finished:
        return run.state.lower()
    if run.succeeded:
        return "succeeded"
    if run.status is SimulationStatus.CANCELLED:
        return "cancelled"
    return "failed"


def completion(run: SimulationInfo) -> float:
    """Return how much of the run is done, from 0 to 1; a finished run counts as done."""
    if run.is_finished:
        return 1.0
    return 0.0 if run.progress is None else run.progress.percent


def elapsed_ms(run: SimulationInfo) -> float | None:
    """Return the wall-clock milliseconds since the run started, until it finished."""
    if run.started_at is None:
        return None
    end = run.finished_at or datetime.now(UTC)
    return (end - run.started_at).total_seconds() * 1000


def format_log(log: LogEvent) -> str:
    """Format a log entry as one line, with the unit and type that raised it when known."""
    source = f"Unit {log.unit_id} Type {log.type_id}: " if log.unit_id is not None else ""
    information = f" ({log.information})" if log.information else ""
    return f"[{log.run_id:>3}] {log.time:>10,.2f} h  {log.severity:<7}  {source}{log.message or ''}{information}\n"


# -----------------------------------------------------------------------------
# Dashboard
# -----------------------------------------------------------------------------
class Dashboard:
    """A window following a daemon's runs: table, overall progress, details, and logs."""

    def __init__(self, root: tk.Tk, daemon: Daemon, connection: sqlite3.Connection) -> None:
        """Build the widgets; call ``tick()`` once to start following the daemon."""
        self.root: tk.Tk = root
        self.daemon: Daemon = daemon
        self.connection: sqlite3.Connection = connection
        # Where the next read starts: only this daemon's changes.
        self.revision: int = daemon.start_revision
        self.log_id: int = daemon.start_log_id
        self.runs: dict[int, SimulationInfo] = {}
        self.logs: list[LogEvent] = []
        self.started_at: datetime = datetime.now(UTC)
        self.following: bool = True

        root.title("TRNRun - batch dashboard")
        root.geometry("1180x720")
        root.protocol("WM_DELETE_WINDOW", self.close)
        self._build_toolbar()
        self._build_panes()
        self.footer: ttk.Label = ttk.Label(root, anchor="w", padding=(8, 2))
        self.footer.pack(fill="x", side="bottom")

    # -----------------------------------------------------------------
    # Layout
    # -----------------------------------------------------------------
    def _build_toolbar(self) -> None:
        """Build the summary, overall progress bar, and action buttons."""
        bar = ttk.Frame(self.root, padding=8)
        bar.pack(fill="x")
        self.summary: ttk.Label = ttk.Label(bar, font=("Segoe UI", 10, "bold"))
        self.summary.pack(side="left")
        self.overall: ttk.Progressbar = ttk.Progressbar(bar, maximum=100, length=260)
        self.overall.pack(side="left", padx=12)
        ttk.Button(bar, text="Cancel all", command=self.cancel_all).pack(side="right")
        ttk.Button(bar, text="Cancel selected", command=self.cancel_selected).pack(side="right", padx=4)
        ttk.Button(bar, text="Add decks...", command=self.add_decks).pack(side="right")

    def _build_panes(self) -> None:
        """Build the run table above, and the details and log panes below it."""
        panes = ttk.Panedwindow(self.root, orient="vertical")
        panes.pack(fill="both", expand=True, padx=8)

        table = ttk.Frame(panes)
        self.tree: ttk.Treeview = ttk.Treeview(table, columns=tuple(COLUMNS), show="headings", selectmode="extended")
        for column, (heading, width, anchor) in COLUMNS.items():
            self.tree.heading(column, text=heading)
            self.tree.column(column, width=width, anchor=anchor, stretch=column == "deck")
        for tag, color in OUTCOME_COLORS.items():
            self.tree.tag_configure(tag, foreground=color)
        self.tree.bind("<<TreeviewSelect>>", self._on_select)
        self._scrolled(table, self.tree)
        panes.add(table, weight=3)

        bottom = ttk.Panedwindow(panes, orient="horizontal")
        details = ttk.Labelframe(bottom, text="Selected run", padding=4)
        self.details: tk.Text = tk.Text(details, width=48, height=12, wrap="word", font=("Consolas", 9))
        self.details.configure(state="disabled")
        self._scrolled(details, self.details)
        bottom.add(details, weight=1)

        logs = ttk.Labelframe(bottom, text="TRNSYS log", padding=4)
        self.only_selected: tk.BooleanVar = tk.BooleanVar(value=False)
        ttk.Checkbutton(logs, text="Only selected runs", variable=self.only_selected, command=self._redraw_logs).pack(
            anchor="w",
        )
        self.log_text: tk.Text = tk.Text(logs, height=12, wrap="none", font=("Consolas", 9))
        for severity, color in SEVERITY_COLORS.items():
            self.log_text.tag_configure(severity, foreground=color)
        self.log_text.configure(state="disabled")
        self._scrolled(logs, self.log_text)
        bottom.add(logs, weight=2)
        panes.add(bottom, weight=2)

    @staticmethod
    def _scrolled(parent: tk.Misc, widget: ttk.Treeview | tk.Text) -> None:
        """Pack ``widget`` into ``parent`` with a vertical scrollbar."""
        scrollbar = ttk.Scrollbar(parent, orient="vertical", command=widget.yview)
        widget.configure(yscrollcommand=scrollbar.set)
        scrollbar.pack(side="right", fill="y")
        widget.pack(side="left", fill="both", expand=True)

    # -----------------------------------------------------------------
    # Actions
    # -----------------------------------------------------------------
    def add(self, deck: Path) -> None:
        """Submit a deck and show it as queued until the daemon reports on it."""
        try:
            run_id = self.daemon.add(deck, SETTINGS, label=deck.stem)
        except (TrnrunError, OSError) as error:  # Rejected, trnrund exited, TRNSYS missing, or no reply.
            _ = messagebox.showerror("TRNRun", f"{deck.name} was not added:\n{error}", parent=self.root)
            return
        self.runs[run_id] = SimulationInfo(run_id, SimulationState.QUEUED, deck_file=deck, label=deck.stem)
        self._draw_row(self.runs[run_id])
        self._draw_summary()

    def add_decks(self) -> None:
        """Ask for decks and submit each one."""
        paths = filedialog.askopenfilenames(
            parent=self.root,
            title="Add decks",
            initialdir=DCK_FOLDER,
            filetypes=[("TRNSYS decks", "*.dck"), ("All files", "*.*")],
        )
        for path in paths:
            self.add(Path(path))

    def cancel(self, run_ids: list[int]) -> None:
        """Cancel runs; they show as cancelled once the daemon has stopped them."""
        try:
            for run_id in run_ids:
                self.daemon.cancel(run_id)
        except TrnrunError as error:  # trnrund exited; tick() reports it.
            self.footer["text"] = str(error)

    def cancel_selected(self) -> None:
        """Cancel the selected runs that have not finished."""
        self.cancel([run_id for run_id in self._selected() if not self.runs[run_id].is_finished])

    def cancel_all(self) -> None:
        """Cancel every unfinished run, after asking."""
        unfinished = [run.run_id for run in self.runs.values() if not run.is_finished]
        if unfinished and messagebox.askyesno("TRNRun", f"Cancel {len(unfinished)} unfinished runs?", parent=self.root):
            self.cancel(unfinished)

    def close(self) -> None:
        """Close the window, after asking if runs would be interrupted."""
        unfinished = sum(not run.is_finished for run in self.runs.values())
        question = f"{unfinished} runs have not finished. Interrupt them and quit?"
        if unfinished and self.following and not messagebox.askyesno("TRNRun", question, parent=self.root):
            return
        # Ends mainloop; leaving the with block in main() then interrupts unfinished runs.
        self.root.destroy()

    # -----------------------------------------------------------------
    # Following the daemon
    # -----------------------------------------------------------------
    def tick(self) -> None:
        """Read what changed, redraw it, and schedule the next tick."""
        try:
            changed = self.daemon.wait_for_changes(self.revision, timeout=0)
        except ClosedError:  # trnrund exited cleanly, and everything it saved was read.
            self.following = False
            return
        except DaemonExitedError as error:  # trnrund crashed, and everything it saved was read.
            self.following = False
            self.footer["text"] = f"trnrund stopped: {error}"
            _ = messagebox.showerror("TRNRun", str(error), parent=self.root)
            return

        runs: list[SimulationInfo] = []
        logs: list[LogEvent] = []
        if changed:
            changes = read_changes(self.connection, self.revision, self.log_id)
            self.revision, self.log_id = changes.revision, changes.log_id
            runs, logs = changes.runs, changes.logs
        for run in runs:
            self.runs[run.run_id] = run
        # Running rows are redrawn every tick so their elapsed time keeps counting.
        redraw = {run.run_id for run in runs}
        redraw |= {run.run_id for run in self.runs.values() if run.state is SimulationState.RUNNING}
        for run_id in sorted(redraw):
            self._draw_row(self.runs[run_id])
        self._append_logs(logs)
        self._draw_summary()
        if redraw & set(self._selected()):
            self._draw_details()

        uptime = (datetime.now(UTC) - self.started_at).total_seconds() * 1000
        self.footer["text"] = (
            f"Database: {self.daemon.database_path}   |   Session {self.daemon.session_id}"
            f"   |   Up {format_duration(uptime)}   |   {MAX_CONCURRENT} at once"
        )
        self.root.after(POLL_MS, self.tick)

    # -----------------------------------------------------------------
    # Drawing
    # -----------------------------------------------------------------
    def _selected(self) -> list[int]:
        """Return the run IDs selected in the table."""
        return [int(iid) for iid in self.tree.selection()]

    def _on_select(self, _event: object) -> None:
        """Show the new selection's details, and its logs if filtered."""
        self._draw_details()
        if self.only_selected.get():
            self._redraw_logs()

    def _draw_row(self, run: SimulationInfo) -> None:
        """Insert or update a run's table row."""
        progress, config = run.progress, run.config
        simulated = "" if progress is None else f"{progress.time:,.0f}"
        if config is not None:
            simulated += f" / {config.stop:,.0f} h"
        eta = progress.eta_ms if progress is not None and run.state is SimulationState.RUNNING else None
        values = (
            run.run_id,
            run.deck_file.name,
            run.state,
            run.status or "",
            format_bar(completion(run)) if run.succeeded or not run.is_finished else "",
            simulated,
            format_duration(elapsed_ms(run)),
            format_duration(eta),
            f"N:{run.notices}  W:{run.warnings}  F:{run.fatals}",
        )
        iid = str(run.run_id)
        if self.tree.exists(iid):
            self.tree.item(iid, values=values, tags=(outcome(run),))
        else:
            _ = self.tree.insert("", "end", iid=iid, values=values, tags=(outcome(run),))

    def _draw_summary(self) -> None:
        """Count the runs by outcome and draw the overall progress."""
        counts = dict.fromkeys(OUTCOME_COLORS, 0)
        for run in self.runs.values():
            counts[outcome(run)] += 1
        overall = sum(map(completion, self.runs.values())) / len(self.runs) if self.runs else 0.0
        parts = "   ".join(f"{name.capitalize()} {count}" for name, count in counts.items())
        self.summary["text"] = f"{len(self.runs)} runs   |   {parts}   |   {overall:.0%}"
        self.overall["value"] = overall * 100
        self.root.title(f"TRNRun - batch dashboard ({overall:.0%})")

    def _draw_details(self) -> None:
        """Describe the single selected run, or say how many are selected."""
        selected = self._selected()
        if len(selected) != 1:
            lines = [f"{len(selected)} runs selected." if selected else "Select a run to see its details."]
        else:
            run = self.runs[selected[0]]
            config = run.config
            span = "" if config is None else f"{config.start:,.0f} to {config.stop:,.0f} h, step {config.step:g} h"
            lines = [
                f"Run       {run.run_id}  ({outcome(run)})",
                f"Deck      {run.deck_file}",
                f"Label     {run.label or ''}",
                f"State     {run.state}",
                f"Status    {run.status or ''}  {run.status_message or ''}",
                f"Error     {run.error or ''}",
                f"Exit code {'' if run.exit_code is None else run.exit_code}",
                f"Simulated {span}",
                f"Submitted {format_timestamp(run.submitted_at)}",
                f"Started   {format_timestamp(run.started_at)}",
                f"Finished  {format_timestamp(run.finished_at)}",
                f"Logs      {run.notices} notices, {run.warnings} warnings, {run.fatals} fatals",
                f"Options   {' '.join(run.trnrun_args)}",
            ]
        self.details.configure(state="normal")
        self.details.delete("1.0", "end")
        self.details.insert("end", "\n".join(lines))
        self.details.configure(state="disabled")

    def _shows(self, log: LogEvent) -> bool:
        """Return whether the log pane shows this entry under the current filter."""
        return not self.only_selected.get() or log.run_id in self._selected()

    def _append_logs(self, logs: list[LogEvent]) -> None:
        """Keep new log entries and append those the filter shows, following the end."""
        self.logs.extend(logs)
        shown = [log for log in logs if self._shows(log)]
        if not shown:
            return
        # Only follow the end if the user has not scrolled up to read.
        at_end = self.log_text.yview()[1] >= 0.999
        self.log_text.configure(state="normal")
        for log in shown:
            self.log_text.insert("end", format_log(log), log.severity)
        self.log_text.configure(state="disabled")
        if at_end:
            self.log_text.see("end")

    def _redraw_logs(self) -> None:
        """Redraw the log pane from every entry kept, under the current filter."""
        self.log_text.configure(state="normal")
        self.log_text.delete("1.0", "end")
        self.log_text.configure(state="disabled")
        logs, self.logs = self.logs, []
        self._append_logs(logs)
        self.log_text.see("end")


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def main() -> None:
    """Copy the master deck, submit every copy, and follow them in the dashboard."""
    dck_files = copy_dck(MASTER_DCK, DCK_FOLDER, n=SIM_COUNT)
    # The connection closes first, before the daemon deletes its temporary database.
    with Daemon(max_concurrent=MAX_CONCURRENT) as daemon, closing(daemon.connect()) as connection:
        root = tk.Tk()
        dashboard = Dashboard(root, daemon, connection)
        for dck in dck_files:
            dashboard.add(dck)
        dashboard.tick()
        root.mainloop()


if __name__ == "__main__":
    main()
