"""Passive terminal progress display for rows read from the daemon database."""

import sqlite3
from collections.abc import Sequence

try:
    from rich.console import Console, Group
    from rich.live import Live
    from rich.segment import Segment
    from rich.text import Text
except ModuleNotFoundError as error:
    if error.name != "rich":
        raise
    raise ImportError("The progress display requires Rich; install 'trnrun[display]'.") from error

PATH_WIDTH = 32
PROGRESS_BAR_WIDTH = 20


def _format_duration(milliseconds: float | None) -> str:
    """Format milliseconds as HH:MM:SS, clamping negative ETA to zero."""
    if milliseconds is None:
        return "--:--:--"
    hours, remainder = divmod(max(int(milliseconds / 1000), 0), 3600)
    minutes, seconds = divmod(remainder, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def _truncate_path(path: str) -> str:
    """Pad or left-truncate a path to a fixed number of terminal cells."""
    segment = Segment(path)
    length = segment.cell_length
    if length <= PATH_WIDTH:
        return path + " " * (PATH_WIDTH - length)
    return "…" + segment.split_cells(length - PATH_WIDTH + 1)[1].text


def _render_line(row: sqlite3.Row) -> Text:
    """Render a database snapshot, using the final outcome for status colour."""
    status = row["trnrun_status"] or row["state"]
    style = None
    if row["state"] == "FINISHED":
        if row["succeeded"]:
            status, style = "DONE", "green"
        elif row["trnrun_status"] == "CANCELLED":
            status, style = "CANCELLED", "yellow"
        else:
            status, style = "ERROR", "red"

    logs = f"N:{row['notices']} W:{row['warnings']} F:{row['fatals']}"
    elapsed = _format_duration(row["elapsed_ms"])
    eta = _format_duration(row["eta_ms"])
    percent = row["percent"]
    filled = min(max(int(PROGRESS_BAR_WIDTH * (percent if percent is not None else 0)), 0), PROGRESS_BAR_WIDTH)
    bar = "[" + "#" * filled + "-" * (PROGRESS_BAR_WIDTH - filled) + "]"
    sim_percent = "" if percent is None else f"({percent * 100:.0f}%)"
    sim_time, sim_stop = row["sim_time"], row["stop_time"]
    sim_progress = "- / -" if sim_time is None or sim_stop is None else f"{sim_time:6,.0f} / {sim_stop:6,.0f}"

    text = Text()
    text.append(f"[{row['run_id']}] {_truncate_path(row['deck_file'])} │ Status: ")
    text.append(f"{status:<10}", style=style)
    text.append(f" │ Logs: {logs:<12} │ Elapsed: {elapsed:<8} │ ETA: {eta:<8} │ ")
    text.append(f"{bar} {sim_progress} {sim_percent:6}")
    return text


class ProgressDisplay:
    """Show RUNNING rows live and print FINISHED rows above them.

    Feed each completion once using the daemon's revision cursor. This display
    has no database connection, polling loop, or background thread of its own.
    """

    def __init__(self, console: Console | None = None) -> None:
        """Use the supplied console or the default terminal console."""
        self.console: Console = console if console is not None else Console()
        self._rows: dict[str, sqlite3.Row] = {}
        self._live: Live | None = None

    def update(self, changed: Sequence[sqlite3.Row]) -> None:
        """Replace changed live rows and print newly finished rows."""
        if not changed:
            return
        for row in changed:
            run_id = row["run_id"]
            if row["state"] == "FINISHED":
                _ = self._rows.pop(run_id, None)
                self.console.print(_render_line(row))
            elif row["state"] == "RUNNING":
                self._rows[run_id] = row

        if not self._rows:
            self.close()
            return
        group = Group(*(_render_line(row) for row in self._rows.values()))
        if self._live is None:
            live = Live(group, console=self.console, auto_refresh=False, transient=True)
            live.start(refresh=True)
            self._live = live
        else:
            self._live.update(group, refresh=True)

    def close(self) -> None:
        """Clear live rows; permanent completion lines remain on the console."""
        self._rows.clear()
        if self._live is not None:
            live, self._live = self._live, None
            live.stop()
