"""Display: one live line per running simulation, and one printed line per finished one.

In a terminal the live lines are a Rich live region; in Jupyter they are one
HTML output area that IPython replaces in place, without widgets or clearing
other cell output.
"""

from collections.abc import Sequence
from io import StringIO

from rich.console import Console, Group
from rich.live import Live
from rich.segment import Segment
from rich.text import Text

from trnrun.simulation import Simulation, SimulationStatus

_STATUS_STYLES: dict[SimulationStatus, str] = {
    SimulationStatus.DONE: "green",
    SimulationStatus.CANCELLED: "yellow",
    SimulationStatus.ERROR: "red",
    SimulationStatus.TIMEOUT: "red",
    SimulationStatus.STALLED: "red",
}
_BAR_WIDTH = 20
_NAME_WIDTH = 32
_NOTEBOOK_FRAME = (
    '<pre style="margin:0;white-space:pre;overflow-x:auto;line-height:1.3;'
    'font-family:monospace;color:inherit;background:transparent">{code}</pre>'
)


def _duration(ms: float | None) -> str:
    """Format milliseconds as HH:MM:SS, or ``--:--:--`` before the runner reported any."""
    if ms is None:
        return "--:--:--"
    minutes, seconds = divmod(max(int(ms // 1000), 0), 60)
    hours, minutes = divmod(minutes, 60)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}"


def _truncate_left(text: str, width: int) -> str:
    """Pad or left-truncate ``text`` to ``width`` terminal cells, marking a cut with ``…``."""
    segment = Segment(text)
    length = segment.cell_length
    if length <= width:
        return text + " " * (width - length)
    return "…" + segment.split_cells(length - width + 1)[1].text


def render(sim: Simulation) -> Text:
    """Render one simulation as one line.

    Parameters
    ----------
    sim : Simulation
        Simulation to render; values not reported yet render as placeholders.

    Returns
    -------
    Text
        ID, name, status, log counts, elapsed time, ETA and progress bar; final statuses are coloured.
    """
    name = sim.label or str(sim.deck_file)
    percent = sim.percent or 0.0
    filled = min(max(int(_BAR_WIDTH * percent), 0), _BAR_WIDTH)
    bar = "[" + "#" * filled + "-" * (_BAR_WIDTH - filled) + "]"
    sim_time = (
        "- / -" if sim.sim_time is None or sim.stop_time is None else f"{sim.sim_time:6,.0f} / {sim.stop_time:6,.0f}"
    )
    sim_percent = "" if sim.percent is None else f"({percent:.0%})"
    status = sim.status or sim.state
    logs = f"N:{sim.notices} W:{sim.warnings} F:{sim.fatals}"
    return Text.assemble(
        f"[{sim.sim_id}] {_truncate_left(name, _NAME_WIDTH)} | Status: ",
        (f"{status:<10}", _STATUS_STYLES.get(sim.status, "") if sim.status is not None else ""),
        f" | Logs: {logs:<12} | Elapsed: {_duration(sim.elapsed_ms):<8} | ETA: {_duration(sim.eta_ms):<8}",
        f" | {bar} {sim_time} {sim_percent:6}",
    )


class _TerminalOutput:
    """Transient Rich live region, started on demand and stopped when empty; printed lines go above it."""

    def __init__(self, console: Console) -> None:
        """Draw on ``console``; nothing shows until the first line."""
        self._console: Console = console
        self._live: Live | None = None

    def show(self, lines: Sequence[Text]) -> None:
        """Redraw the live region, starting it on demand and stopping it when empty."""
        if not lines:
            self.close()
            return
        group = Group(*lines)
        if self._live is None:
            self._live = Live(group, console=self._console, auto_refresh=False, transient=True)
            self._live.start(refresh=True)
        else:
            self._live.update(group, refresh=True)

    def print(self, line: Text) -> None:
        """Print a line above the live region."""
        self._console.print(line)

    def close(self) -> None:
        """Stop and erase the live region; printed lines stay."""
        if self._live is not None:
            live, self._live = self._live, None
            live.stop()


class _NotebookOutput:
    """One HTML output area, replaced in place; printed lines go to stdout with ANSI colours.

    Rich's own live display needs ipywidgets in Jupyter, so the lines are
    exported as HTML instead. Unchanged frames are not published.
    """

    def __init__(self) -> None:
        """Prepare the output area; it is published with the first line."""
        from IPython.display import HTML, DisplayHandle  # noqa: PLC0415 - not a dependency outside notebooks

        self._html: type[HTML] = HTML
        self._new_handle: type[DisplayHandle] = DisplayHandle
        self._printer: Console = Console(force_jupyter=False, force_terminal=True, color_system="standard")
        self._handle: DisplayHandle | None = None
        self._last_html: str | None = None

    def show(self, lines: Sequence[Text]) -> None:
        """Replace the output area, publishing it on first use."""
        if self._handle is None and not lines:
            return
        # A fresh, private console per frame keeps buffers bounded and bypasses Rich's Jupyter output.
        frame = Console(file=StringIO(), record=True, force_jupyter=False, color_system=None)
        frame.print(Group(*lines), soft_wrap=True)
        html = frame.export_html(inline_styles=True, code_format=_NOTEBOOK_FRAME)
        if html == self._last_html:
            return
        if self._handle is None:
            self._handle = self._new_handle()
            _ = self._handle.display(self._html(html))
        else:
            self._handle.update(self._html(html))
        self._last_html = html

    def print(self, line: Text) -> None:
        """Print a line to stdout."""
        self._printer.print(line, soft_wrap=True)

    def close(self) -> None:
        """Release the output area without publishing; the next frame starts a new one."""
        self._handle = None
        self._last_html = None


class Display:
    """Live lines of running simulations; finished ones are printed above them, once.

    A Jupyter console, the default inside a notebook, gets an in-place HTML
    output area instead of a Rich live region.
    """

    def __init__(self, console: Console | None = None) -> None:
        """Prepare the display; nothing shows until the first update.

        Parameters
        ----------
        console : Console, optional
            Console to draw on, a new one by default; a Jupyter console gets the HTML output area.
        """
        console = console or Console()
        self._output: _TerminalOutput | _NotebookOutput = (
            _NotebookOutput() if console.is_jupyter else _TerminalOutput(console)
        )

    def update(self, running: list[Simulation], finished: list[Simulation]) -> None:
        """Print the newly finished simulations, then redraw the running ones.

        Parameters
        ----------
        running : list of Simulation
            Simulations shown as live lines; they replace the previous ones.
        finished : list of Simulation
            Simulations printed once above the live lines; pass each only once.
        """
        for sim in finished:
            self._output.print(render(sim))
        self._output.show([render(sim) for sim in running])

    def close(self) -> None:
        """Erase the live lines; printed lines stay."""
        self._output.close()
