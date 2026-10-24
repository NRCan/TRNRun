"""Example: a developer-owned tkinter dashboard using only the thin Daemon client.

Like ``example_manager.py``, it copies one master deck ``SIM_COUNT`` times and
runs every copy, but follows them in a window: a live table of simulations,
overall progress, the selected simulation's details, and a log of every TRNSYS
message. Decks can be added and simulations cancelled while the batch runs.

It does not use ``SimulationManager``: the application owns its widgets and
its timer. Each tick lists the running and finished simulations, with all
their logs, then releases the finished ones, which it keeps itself. Queued
simulations change only by starting or finishing, so two requests a tick
follow every simulation, however many there are.
"""

from __future__ import annotations

import shutil
import tkinter as tk
from contextlib import suppress
from datetime import UTC, datetime
from pathlib import Path
from tkinter import filedialog, messagebox, ttk
from typing import Literal

from trnrun import (
    Daemon,
    DaemonExitedError,
    LogEvent,
    LogSeverity,
    RequestError,
    Simulation,
    SimulationSettings,
    SimulationState,
    SimulationStatus,
    TrnrunError,
)

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
HERE = Path(__file__).resolve().parent

TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")
MASTER_DCK = HERE / "dck" / "example_wo_plot_w_tracking.dck"
DCK_FOLDER = HERE / "runs"

SIM_COUNT = 10
WORKERS = 5
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


def format_hours(value: float | None) -> str:
    """Format simulated hours with thousands separators; blank when unknown."""
    return "" if value is None else f"{value:,.0f}"


def outcome(sim: Simulation) -> str:
    """Return the simulation's row tag: queued, running, succeeded, cancelled or failed."""
    if not sim.is_finished:
        return sim.state.lower()
    if sim.succeeded:
        return "succeeded"
    if sim.status is SimulationStatus.CANCELLED:
        return "cancelled"
    return "failed"


def completion(sim: Simulation) -> float:
    """Return how much of the simulation is done, from 0 to 1; a finished one counts as done."""
    if sim.is_finished:
        return 1.0
    return sim.percent or 0.0


def wall_ms(sim: Simulation) -> float | None:
    """Return the wall-clock milliseconds since the simulation started, until it finished."""
    if sim.started_at is None:
        return None
    end = sim.finished_at or datetime.now(UTC)
    return (end - sim.started_at).total_seconds() * 1000


def format_log(sim_id: int, log: LogEvent) -> str:
    """Format a log entry of simulation ``sim_id`` as one line, with the unit and type that raised it when known."""
    source = f"Unit {log.unit_id} Type {log.type_id}: " if log.unit_id is not None else ""
    information = f" ({log.information})" if log.information else ""
    return f"[{sim_id:>3}] {log.time:>10,.2f} h  {log.severity:<7}  {source}{log.message or ''}{information}\n"


# -----------------------------------------------------------------------------
# Dashboard
# -----------------------------------------------------------------------------
class Dashboard:
    """A window following a daemon's simulations: table, overall progress, details, and logs."""

    def __init__(self, root: tk.Tk, daemon: Daemon) -> None:
        """Build the widgets; call ``tick()`` once to start following the daemon."""
        self.root: tk.Tk = root
        self.daemon: Daemon = daemon
        self.sims: dict[int, Simulation] = {}
        self.logs: list[tuple[int, LogEvent]] = []  # Every entry read, with its simId.
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
        """Build the simulation table above, and the details and log panes below it."""
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
        details = ttk.Labelframe(bottom, text="Selected simulation", padding=4)
        self.details: tk.Text = tk.Text(details, width=48, height=12, wrap="word", font=("Consolas", 9))
        self.details.configure(state="disabled")
        self._scrolled(details, self.details)
        bottom.add(details, weight=1)

        logs = ttk.Labelframe(bottom, text="TRNSYS log", padding=4)
        self.only_selected: tk.BooleanVar = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            logs,
            text="Only selected simulations",
            variable=self.only_selected,
            command=self._redraw_logs,
        ).pack(anchor="w")
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
        """Submit a deck and show it as the daemon first reports it."""
        try:
            sim = self.daemon.get(self.daemon.add(deck, SETTINGS, label=deck.stem))
        except TrnrunError as error:  # Rejected, or trnrund exited.
            _ = messagebox.showerror("TRNRun", f"{deck.name} was not added:\n{error}", parent=self.root)
            return
        self.sims[sim.sim_id] = sim
        self._draw_row(sim)
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

    def cancel(self, sim_ids: list[int]) -> None:
        """Cancel simulations; they show as cancelled once the daemon has stopped them."""
        try:
            for sim_id in sim_ids:
                with suppress(RequestError):  # It finished since the last tick.
                    self.daemon.cancel(sim_id)
        except DaemonExitedError as error:  # tick() reports it.
            self.footer["text"] = str(error)

    def cancel_selected(self) -> None:
        """Cancel the selected simulations that have not finished."""
        self.cancel([sim_id for sim_id in self._selected() if not self.sims[sim_id].is_finished])

    def cancel_all(self) -> None:
        """Cancel every unfinished simulation, after asking."""
        unfinished = [sim.sim_id for sim in self.sims.values() if not sim.is_finished]
        question = f"Cancel {len(unfinished)} unfinished simulations?"
        if unfinished and messagebox.askyesno("TRNRun", question, parent=self.root):
            self.cancel(unfinished)

    def close(self) -> None:
        """Close the window, after asking if simulations would be interrupted."""
        unfinished = sum(not sim.is_finished for sim in self.sims.values())
        question = f"{unfinished} simulations have not finished. Interrupt them and quit?"
        if unfinished and self.following and not messagebox.askyesno("TRNRun", question, parent=self.root):
            return
        # Ends mainloop; leaving the with block in main() then interrupts unfinished simulations.
        self.root.destroy()

    # -----------------------------------------------------------------
    # Following the daemon
    # -----------------------------------------------------------------
    def tick(self) -> None:
        """List running and finished simulations, redraw what changed, release finished ones, and schedule the next tick."""
        try:
            running = self.daemon.list(SimulationState.RUNNING, with_logs=True)
            finished = self.daemon.list(SimulationState.FINISHED, with_logs=True)
            # One that finished between the two lists is in both; the finished one wins.
            sims = list({sim.sim_id: sim for sim in running + finished}.values())
            for sim in finished:  # Their logs are complete; this window keeps them.
                self.daemon.release(sim.sim_id)
        except DaemonExitedError as error:  # trnrund crashed.
            self.following = False
            self.footer["text"] = f"trnrund stopped: {error}"
            _ = messagebox.showerror("TRNRun", str(error), parent=self.root)
            return

        sims = [sim for sim in sims if self.sims[sim.sim_id] != sim]
        logs = [(sim.sim_id, log) for sim in sims for log in sim.logs[len(self.sims[sim.sim_id].logs) :]]
        for sim in sims:
            self.sims[sim.sim_id] = sim
        # Running rows are redrawn every tick so their elapsed time keeps counting.
        redraw = {sim.sim_id for sim in sims}
        redraw |= {sim.sim_id for sim in self.sims.values() if sim.state is SimulationState.RUNNING}
        for sim_id in sorted(redraw):
            self._draw_row(self.sims[sim_id])
        self._append_logs(logs)
        self._draw_summary()
        if redraw & set(self._selected()):
            self._draw_details()

        uptime = (datetime.now(UTC) - self.started_at).total_seconds() * 1000
        self.footer["text"] = f"Up {format_duration(uptime)}   |   {WORKERS} workers"
        self.root.after(POLL_MS, self.tick)

    # -----------------------------------------------------------------
    # Drawing
    # -----------------------------------------------------------------
    def _selected(self) -> list[int]:
        """Return the simIds selected in the table."""
        return [int(iid) for iid in self.tree.selection()]

    def _on_select(self, _event: object) -> None:
        """Show the new selection's details, and its logs if filtered."""
        self._draw_details()
        if self.only_selected.get():
            self._redraw_logs()

    def _draw_row(self, sim: Simulation) -> None:
        """Insert or update a simulation's table row."""
        simulated = format_hours(sim.sim_time)
        if sim.stop_time is not None:
            simulated += f" / {sim.stop_time:,.0f} h"
        eta = sim.eta_ms if sim.state is SimulationState.RUNNING else None
        values = (
            sim.sim_id,
            sim.deck_file.name,
            sim.state,
            sim.status or "",
            format_bar(completion(sim)) if sim.succeeded or not sim.is_finished else "",
            simulated,
            format_duration(wall_ms(sim)),
            format_duration(eta),
            f"N:{sim.notices}  W:{sim.warnings}  F:{sim.fatals}",
        )
        iid = str(sim.sim_id)
        if self.tree.exists(iid):
            self.tree.item(iid, values=values, tags=(outcome(sim),))
        else:
            _ = self.tree.insert("", "end", iid=iid, values=values, tags=(outcome(sim),))

    def _draw_summary(self) -> None:
        """Count the simulations by outcome and draw the overall progress."""
        counts = dict.fromkeys(OUTCOME_COLORS, 0)
        for sim in self.sims.values():
            counts[outcome(sim)] += 1
        overall = sum(map(completion, self.sims.values())) / len(self.sims) if self.sims else 0.0
        parts = "   ".join(f"{name.capitalize()} {count}" for name, count in counts.items())
        self.summary["text"] = f"{len(self.sims)} simulations   |   {parts}   |   {overall:.0%}"
        self.overall["value"] = overall * 100
        self.root.title(f"TRNRun - batch dashboard ({overall:.0%})")

    def _draw_details(self) -> None:
        """Describe the single selected simulation, or say how many are selected."""
        selected = self._selected()
        if len(selected) != 1:
            lines = [
                f"{len(selected)} simulations selected." if selected else "Select a simulation to see its details.",
            ]
        else:
            sim = self.sims[selected[0]]
            span = ""
            if sim.start_time is not None and sim.stop_time is not None:
                span = f"{sim.start_time:,.0f} to {sim.stop_time:,.0f} h, step {sim.time_step or 0:g} h"
            lines = [
                f"Sim       {sim.sim_id}  ({outcome(sim)})",
                f"Deck      {sim.deck_file}",
                f"Label     {sim.label or ''}",
                f"State     {sim.state}",
                f"Status    {sim.status or ''}  {sim.status_message or ''}",
                f"Error     {sim.error or ''}",
                f"Exit code {'' if sim.exit_code is None else sim.exit_code}",
                f"Simulated {span}",
                f"Submitted {format_timestamp(sim.submitted_at)}",
                f"Started   {format_timestamp(sim.started_at)}",
                f"Finished  {format_timestamp(sim.finished_at)}",
                f"Logs      {sim.notices} notices, {sim.warnings} warnings, {sim.fatals} fatals",
                f"Options   {' '.join(sim.trnrun_args)}",
            ]
        self.details.configure(state="normal")
        self.details.delete("1.0", "end")
        self.details.insert("end", "\n".join(lines))
        self.details.configure(state="disabled")

    def _shows(self, sim_id: int) -> bool:
        """Return whether the log pane shows simulation ``sim_id``'s entries under the current filter."""
        return not self.only_selected.get() or sim_id in self._selected()

    def _append_logs(self, logs: list[tuple[int, LogEvent]]) -> None:
        """Keep new log entries and append those the filter shows, following the end."""
        self.logs.extend(logs)
        shown = [(sim_id, log) for sim_id, log in logs if self._shows(sim_id)]
        if not shown:
            return
        # Only follow the end if the user has not scrolled up to read.
        at_end = self.log_text.yview()[1] >= 0.999
        self.log_text.configure(state="normal")
        for sim_id, log in shown:
            self.log_text.insert("end", format_log(sim_id, log), log.severity)
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
    with Daemon(workers=WORKERS) as daemon:
        root = tk.Tk()
        dashboard = Dashboard(root, daemon)
        for dck in dck_files:
            dashboard.add(dck)
        dashboard.tick()
        root.mainloop()


if __name__ == "__main__":
    main()
