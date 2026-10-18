"""Progress displays for ``SimulationManager`` runs.

``SimulationManager`` calls its display's ``update`` from its background
thread after every sync that changed a run, with those runs, and ``close`` on
shutdown. Any object with those two methods, a ``Display``, can replace the
built-in ``ProgressDisplay``.

``ProgressDisplay`` keeps one live line per running simulation, and prints
each finished run once as a final line above them. In a terminal the live
lines are a Rich live region; in Jupyter they are one HTML output area that
IPython replaces in place, without widgets or clearing other cell output.
Lines use only characters the Windows ``cp1252`` code page can encode, so
redirected output works too.
"""

# pyright: reportUnusedCallResult=false

from collections.abc import Sequence
from io import StringIO
from typing import Protocol

from rich.console import Console, Group
from rich.live import Live
from rich.segment import Segment
from rich.text import Text

from trnrun.core.records import SimulationState, SimulationStatus
from trnrun.simulation import Simulation

# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
# Final statuses are coloured; the others stay plain.
STATUS_STYLES: dict[SimulationStatus, str] = {
    SimulationStatus.DONE: "green",
    SimulationStatus.CANCELLED: "yellow",
    SimulationStatus.ERROR: "red",
    SimulationStatus.TIMEOUT: "red",
    SimulationStatus.STALLED: "red",
}
PATH_WIDTH = 32
PROGRESS_BAR_WIDTH = 20
NOTEBOOK_FRAME = (
    '<pre style="margin:0;white-space:pre;overflow-x:auto;line-height:1.3;'
    'font-family:monospace;color:inherit;background:transparent">{code}</pre>'
)


# -----------------------------------------------------------------
# Display
# -----------------------------------------------------------------
class Display(Protocol):
    """What ``SimulationManager`` drives, from its background thread."""

    def update(self, changed: Sequence[Simulation]) -> None:
        """Show the runs that changed in the latest sync, in submission order."""

    def close(self) -> None:
        """Release output resources; the manager calls it once, on shutdown."""


# -----------------------------------------------------------------
# Line rendering
# -----------------------------------------------------------------
def _format_duration(ms: float | None) -> str:
    """Format milliseconds as HH:MM:SS, or ``--:--:--`` for None."""
    if ms is None:
        return "--:--:--"
    # A negative ETA is clamped: floor division would render it as "-1:59:55".
    minutes, seconds = divmod(max(int(ms // 1000), 0), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def _truncate_left(text: str, width: int) -> str:
    """Pad or left-truncate ``text`` to ``width`` terminal cells, marking a cut with ``…``.

    Rich replaces a partially cut wide character with a space.
    """
    segment = Segment(text)
    length = segment.cell_length
    if length <= width:
        return text + " " * (width - length)
    return "…" + segment.split_cells(length - width + 1)[1].text


def _render_line(simulation: Simulation) -> Text:
    """Render one simulation as a status line; missing progress renders as placeholders."""
    info = simulation.info
    status = info.status
    progress = info.progress
    stop = info.config.stop if info.config is not None else None

    percent = progress.percent if progress is not None else 0.0
    filled = min(max(int(PROGRESS_BAR_WIDTH * percent), 0), PROGRESS_BAR_WIDTH)
    bar = "[" + "#" * filled + "-" * (PROGRESS_BAR_WIDTH - filled) + "]"
    sim_time = "- / -" if progress is None or stop is None else f"{progress.time:6,.0f} / {stop:6,.0f}"
    sim_percent = f"({percent:.0%})" if progress is not None else ""
    elapsed = _format_duration(progress.elapsed_ms if progress is not None else None)
    eta = _format_duration(progress.eta_ms if progress is not None else None)
    logs = f"N:{info.notices} W:{info.warnings} F:{info.fatals}"

    return Text.assemble(
        f"[{simulation.run_id}] {_truncate_left(str(simulation.deck_file), PATH_WIDTH)} | Status: ",
        (f"{status or '':<10}", STATUS_STYLES.get(status, "") if status is not None else ""),
        f" | Logs: {logs:<12} | Elapsed: {elapsed:<8} | ETA: {eta:<8} | {bar} {sim_time} {sim_percent:6}",
    )


# -----------------------------------------------------------------
# Terminal output
# -----------------------------------------------------------------
class _TerminalOutput:
    """Transient Rich live region of lines, with final lines printed above it.

    The region exists only while there are lines, and redraws only when
    shown, never on a timer of its own.
    """

    def __init__(self, console: Console) -> None:
        self._console: Console = console
        self._live: Live | None = None

    def show(self, lines: Sequence[Text]) -> None:
        """Redraw the live region, starting it on demand and stopping it when empty."""
        if not lines:
            self.close()
            return

        group = Group(*lines)
        if self._live is None:
            live = Live(group, console=self._console, auto_refresh=False, transient=True)
            live.start(refresh=True)
            self._live = live
        else:
            self._live.update(group, refresh=True)

    def print(self, line: Text) -> None:
        """Print a final line above the live region."""
        self._console.print(line)

    def close(self) -> None:
        """Stop and erase the live region; printed lines stay."""
        if self._live is not None:
            live, self._live = self._live, None
            live.stop()


# -----------------------------------------------------------------
# Notebook output
# -----------------------------------------------------------------
class _NotebookOutput:
    """Notebook view with one live HTML output area.

    Rich's own live display needs ipywidgets in Jupyter, so the lines are
    exported as HTML instead. Each final line is printed once to stdout with
    ANSI status colours, never included in later updates. Unchanged frames are
    not published.
    """

    def __init__(self) -> None:
        # Only created inside a notebook kernel, where IPython is always installed.
        from IPython.display import HTML, DisplayHandle  # noqa: PLC0415 - not a dependency outside notebooks

        self._html: type[HTML] = HTML
        self._new_handle: type[DisplayHandle] = DisplayHandle
        self._completed_console: Console = Console(force_jupyter=False, force_terminal=True, color_system="standard")
        self._handle: DisplayHandle | None = None
        self._last_html: str | None = None

    def show(self, lines: Sequence[Text]) -> None:
        """Replace the live output area, publishing it on first use."""
        if self._handle is None and not lines:
            return

        # A fresh, private console per frame keeps buffers bounded and bypasses Rich's Jupyter output.
        frame = Console(file=StringIO(), record=True, force_jupyter=False, color_system=None)
        frame.print(Group(*lines), soft_wrap=True)
        html = frame.export_html(inline_styles=True, code_format=NOTEBOOK_FRAME)
        if html == self._last_html:
            return

        if self._handle is None:
            self._handle = self._new_handle()
            self._handle.display(self._html(html))
        else:
            self._handle.update(self._html(html))
        self._last_html = html

    def print(self, line: Text) -> None:
        """Print a final line to stdout."""
        self._completed_console.print(line, soft_wrap=True)

    def close(self) -> None:
        """Release the output area without publishing; the next frame starts a new one."""
        self._handle = None
        self._last_html = None


# -----------------------------------------------------------------
# Progress Display
# -----------------------------------------------------------------
class ProgressDisplay:
    """Show live progress of a manager's runs, as the manager reports their changes.

    Each ``update`` prints every run that finished, once, as a final line, and
    redraws one live line per running simulation, in the order they started. Queued runs are never drawn, so a redraw costs at most
    ``max_concurrent`` lines however many runs wait. It has no thread of its
    own: ``SimulationManager`` creates one by default and calls it.

    Parameters
    ----------
    console : rich.console.Console, optional
        Console to draw on, by default a new one. A Jupyter console, the
        default inside a notebook, gets an in-place HTML output area instead
        of a Rich live region.
    """

    def __init__(self, console: Console | None = None) -> None:
        console = console if console is not None else Console()
        self._output: _TerminalOutput | _NotebookOutput = (
            _NotebookOutput() if console.is_jupyter else _TerminalOutput(console)
        )
        # Running simulations, by ID, in the order seen.
        self._rows: dict[int, Simulation] = {}

    def update(self, changed: Sequence[Simulation]) -> None:
        """Print the runs that finished, then redraw the unfinished ones."""
        for simulation in changed:
            state = simulation.state
            if state is SimulationState.FINISHED:
                _ = self._rows.pop(simulation.run_id, None)
                self._output.print(_render_line(simulation))
            elif state is not SimulationState.QUEUED:
                _ = self._rows.setdefault(simulation.run_id, simulation)
        self._output.show([_render_line(simulation) for simulation in self._rows.values()])

    def close(self) -> None:
        """Clear the live lines and release the output; printed lines stay."""
        self._rows.clear()
        self._output.close()
