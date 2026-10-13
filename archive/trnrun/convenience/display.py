"""Built-in progress display for TRNRun-manager simulations.

``SimulationManager`` calls its display's ``update`` from its background
thread after every poll that changed a run, with those runs, and ``close`` on
shutdown. Any object with those two methods, a ``Display``, can replace the
built-in ``ProgressDisplay``.

``ProgressDisplay`` keeps one live line per run a worker has taken, and prints
each finished run once as a final line above them. Rich renders the same lines
for terminals and notebooks, and IPython ``DisplayHandle`` replaces notebook
output in place without widgets or clearing other cell output.
"""

# pyright: reportUnusedCallResult=false

from __future__ import annotations

import builtins
from collections.abc import Callable, Sequence
from io import StringIO
from typing import Protocol, cast

try:
    from rich.console import Console, Group
    from rich.live import Live
    from rich.text import Text
except ModuleNotFoundError as exc:
    if exc.name != "rich":
        raise
    raise ImportError(
        "The built-in progress display requires Rich. Install it with pip install 'trnrun[display]', or use SimulationManager(display=False).",
    ) from exc


from trnrun.convenience.simulation import Simulation
from trnrun.convenience.utils import format_hhmmss, truncate_left
from trnrun.events import SimulationState, SimulationStatus

# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
COLOR_MAP: dict[SimulationStatus, str | None] = {
    SimulationStatus.PENDING: None,
    SimulationStatus.LAUNCHING: None,
    SimulationStatus.RUNNING: None,
    SimulationStatus.DONE: "green",
    SimulationStatus.ERROR: "red",
    SimulationStatus.TIMEOUT: "red",
    SimulationStatus.STALLED: "red",
    SimulationStatus.CANCELLED: "yellow",
}

PATH_WIDTH = 32
PROGRESS_BAR_WIDTH = 20
MS_PER_SECOND = 1000


class _DisplayHandle(Protocol):
    """Subset of an IPython ``DisplayHandle`` used by the notebook output."""

    def update(self, obj: object) -> None:
        """Replace the existing output with ``obj``."""


# -----------------------------------------------------------------
# Shared rendering helpers
# -----------------------------------------------------------------
def _progress_bar(percent: float, width: int = PROGRESS_BAR_WIDTH) -> str:
    """Return a fixed-width ASCII completion bar."""
    filled = min(max(int(width * percent), 0), width)
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def _render_line(simulation: Simulation) -> Text:
    """Render one simulation as a shared Rich status line."""
    info = simulation.info
    path = truncate_left(str(simulation.deck_path), PATH_WIDTH)

    status = info.status.status if info.status is not None else None
    status_text = status.value if status is not None else ""
    status_style = COLOR_MAP.get(status) if status is not None else None

    logs = f"N:{info.notices} W:{info.warnings} F:{info.fatals}"

    progress = info.progress

    elapsed = format_hhmmss(progress.elapsed_ms / MS_PER_SECOND if progress else None)
    eta = format_hhmmss(progress.eta_ms / MS_PER_SECOND if progress else None)

    sim_time = progress.time if progress else None
    percent = progress.percent if progress else None

    sim_stop = info.config.stop if info.config else None

    bar = _progress_bar(percent if percent is not None else 0.0)
    sim_percent = "" if percent is None else f"({percent * 100:.0f}%)"

    sim_progress = "- / -" if sim_time is None or sim_stop is None else f"{sim_time:6,.0f} / {sim_stop:6,.0f}"

    text = Text()
    text.append(f"[{simulation.id}] ")
    text.append(f"{path} │ ")
    text.append("Status: ")
    text.append(f"{status_text:<10}", style=status_style)
    text.append(" │ ")
    text.append(f"Logs: {logs:<12} │ ")
    text.append(f"Elapsed: {elapsed:<8} │ ETA: {eta:<8} │ ")
    text.append(f"{bar} {sim_progress} {sim_percent:6}")
    return text


def _in_notebook_kernel() -> bool:
    """Detect an active IPython kernel without importing IPython."""
    get_ipython = getattr(builtins, "get_ipython", None)
    if not callable(get_ipython):
        return False

    try:
        shell = get_ipython()
    except Exception:  # noqa: BLE001 - environment detection must safely fall back
        return False
    return shell is not None and getattr(shell, "kernel", None) is not None


def _load_notebook_api() -> tuple[Callable[[str], object], Callable[..., object]]:
    """Load the optional IPython display API only for notebook rendering."""
    try:
        from IPython.display import HTML, display  # noqa: PLC0415 - optional dependency
    except ImportError as error:
        raise ImportError("Notebook display mode requires IPython") from error
    return cast("Callable[[str], object]", HTML), cast("Callable[..., object]", display)


# -----------------------------------------------------------------
# Terminal output
# -----------------------------------------------------------------
class _TerminalOutput:
    """Transient Rich live region of lines, with final lines printed above it.

    The region exists only while there are lines, and redraws only when
    shown, never on a timer of its own.
    """

    def __init__(self, console: Console | None = None) -> None:
        self.console: Console = console if console is not None else Console()
        self._live: Live | None = None

    def show(self, lines: Sequence[Text]) -> None:
        """Redraw the live region, starting it on demand and stopping it when empty."""
        if not lines:
            self.close()
            return

        group = Group(*lines)
        if self._live is None:
            live = Live(group, console=self.console, auto_refresh=False, transient=True)
            live.start(refresh=True)
            self._live = live
        else:
            self._live.update(group, refresh=True)

    def print(self, line: Text) -> None:
        """Print a final line above the live region."""
        self.console.print(line)

    def close(self) -> None:
        """Stop and erase the live region; printed lines stay."""
        if self._live is not None:
            live, self._live = self._live, None
            live.stop()


# -----------------------------------------------------------------
# Notebook output
# -----------------------------------------------------------------
class _NotebookOutput:
    """Notebook view with one live output area.

    Each final line is printed once to stdout with ANSI status colours, never
    included in later updates. Unchanged frames are not published. Rich exports
    unwrapped status lines as HTML without widgets.
    """

    def __init__(self) -> None:
        html, display_html = _load_notebook_api()
        self._html: Callable[[str], object] = html
        self._display_html: Callable[..., object] = display_html
        self._completed_console: Console = Console(
            force_jupyter=False,
            force_terminal=True,
            color_system="standard",
        )
        self._handle: _DisplayHandle | None = None
        self._last_html: str | None = None

    def show(self, lines: Sequence[Text]) -> None:
        """Replace the live output area, publishing it on first use."""
        if self._handle is None and not lines:
            return

        html = self._render_html(lines)
        if html == self._last_html:
            return

        rendered = self._html(html)
        if self._handle is None:
            handle = self._display_html(rendered, display_id=True)
            if handle is None or not hasattr(handle, "update"):
                raise RuntimeError("IPython did not return a display handle")
            self._handle = cast("_DisplayHandle", handle)
        else:
            self._handle.update(rendered)
        self._last_html = html

    def print(self, line: Text) -> None:
        """Print a final line to stdout."""
        self._completed_console.print(line, soft_wrap=True)

    def close(self) -> None:
        """Release the handle without publishing."""
        self._handle = None
        self._last_html = None

    @staticmethod
    def _render_html(lines: Sequence[Text]) -> str:
        """Export only the supplied lines as a Rich HTML fragment."""
        if not lines:
            return ""

        # A fresh, private console keeps frame buffers bounded and bypasses Rich's
        # Jupyter output hook; publishing is handled explicitly by the caller.
        console = Console(file=StringIO(), record=True, force_jupyter=False, color_system=None)
        console.print(Group(*lines), soft_wrap=True)
        return console.export_html(
            inline_styles=True,
            code_format=(
                '<pre style="margin:0;white-space:pre;overflow-x:auto;line-height:1.3;'
                'font-family:monospace;color:inherit;background:transparent">{code}</pre>'
            ),
        )


def _auto_output(console: Console | None) -> _TerminalOutput | _NotebookOutput:
    """Select the given console, else the environment's output, without eagerly importing IPython."""
    if console is None and _in_notebook_kernel():
        return _NotebookOutput()
    return _TerminalOutput(console)


# -----------------------------------------------------------------
# Progress Display
# -----------------------------------------------------------------
class ProgressDisplay:
    """Show live progress of a manager's runs, as the manager reports their changes.

    Each ``update`` prints every run that finished, once, as a final line, and
    redraws one live line per unfinished run a worker has taken, in the order
    they were taken. Queued runs are never drawn, so a redraw costs at most
    ``max_concurrent`` lines however many runs wait. It has no thread of its
    own: ``SimulationManager`` creates one by default and calls it.

    Parameters
    ----------
    console : rich.console.Console, optional
        Terminal console to draw on; by default a notebook output inside a
        Jupyter kernel, otherwise the standard terminal.
    """

    def __init__(self, console: Console | None = None) -> None:
        self._output: _TerminalOutput | _NotebookOutput = _auto_output(console)
        # Unfinished runs a worker took, by ID, in the order seen.
        self._rows: dict[int, Simulation] = {}

    def update(self, changed: Sequence[Simulation]) -> None:
        """Print the runs that finished, then redraw the unfinished ones."""
        for simulation in changed:
            state = simulation.state
            if state is SimulationState.FINISHED:
                _ = self._rows.pop(simulation.id, None)
                self._output.print(_render_line(simulation))
            elif state is not SimulationState.QUEUED:
                _ = self._rows.setdefault(simulation.id, simulation)
        self._output.show([_render_line(simulation) for simulation in self._rows.values()])

    def close(self) -> None:
        """Clear the live lines and release the output; printed lines stay."""
        self._rows.clear()
        self._output.close()
