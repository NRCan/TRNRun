"""Built-in progress display for TRNRun-manager simulations.

``ProgressDisplay`` reads a ``SimulationManager``'s runs and redraws from its
own background thread, so nothing blocks the caller. It only reads the run
handles; the manager's updates keep them current. It follows only the
manager's ``started`` runs, those a daemon worker has accepted, so it never
reads the queue and draws at most ``max_concurrent`` lines.
Each redraw reads immutable snapshots of those handles, prints each
finished run once, then stops following it. Renderers only ever receive
snapshots: Rich renders the same status lines for terminals and notebooks, and
IPython ``DisplayHandle`` replaces notebook output in place without widgets or
clearing other cell output.
"""

# pyright: reportUnusedCallResult=false

from __future__ import annotations

import builtins
import logging
from collections.abc import Callable, Sequence
from io import StringIO
from threading import Event, Lock, Thread, current_thread
from types import TracebackType
from typing import TYPE_CHECKING, Protocol, Self, cast

from rich.console import Console, Group
from rich.live import Live
from rich.text import Text

from trnrun.events import SimulationStatus
from trnrun.simulation import Simulation, SimulationSnapshot
from trnrun.utils import format_hhmmss, truncate_left

if TYPE_CHECKING:
    # The manager owns a display, so importing it at runtime would be circular.
    from trnrun.manager import SimulationManager

logger = logging.getLogger(__name__)

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


class Renderer(Protocol):
    """Output surface driven by ``ProgressDisplay`` from one thread at a time."""

    def show(self, active: Sequence[SimulationSnapshot]) -> None:
        """Replace the live region with the unfinished runs, or clear it when empty."""

    def finished(self, snapshot: SimulationSnapshot) -> None:
        """Print the final state of a run once, outside the live region."""

    def close(self) -> None:
        """Release output resources."""


class _DisplayHandle(Protocol):
    """Subset of an IPython ``DisplayHandle`` used by the notebook renderer."""

    def update(self, obj: object) -> None:
        """Replace the existing output with ``obj``."""


# -----------------------------------------------------------------
# Shared rendering helpers
# -----------------------------------------------------------------
def _progress_bar(percent: float, width: int = PROGRESS_BAR_WIDTH) -> str:
    """Return a fixed-width ASCII completion bar."""
    filled = min(max(int(width * percent), 0), width)
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def _render_line(snapshot: SimulationSnapshot) -> Text:
    """Render one snapshot as a shared Rich status line."""
    path = truncate_left(str(snapshot.deck_path), PATH_WIDTH)

    status = snapshot.status
    status_text = status.value if status is not None else ""
    status_style = COLOR_MAP.get(status) if status is not None else None

    logs = f"N:{snapshot.notices} W:{snapshot.warnings} F:{snapshot.fatals}"

    progress = snapshot.progress

    elapsed = format_hhmmss(progress.elapsed_ms / MS_PER_SECOND if progress else None)
    eta = format_hhmmss(progress.eta_ms / MS_PER_SECOND if progress else None)

    sim_time = progress.time if progress else None
    percent = progress.percent if progress else None

    config = snapshot.config_event
    sim_stop = config.stop if config else None

    bar = _progress_bar(percent if percent is not None else 0.0)
    sim_percent = "" if percent is None else f"({percent * 100:.0f}%)"

    sim_progress = "- / -" if sim_time is None or sim_stop is None else f"{sim_time:6,.0f} / {sim_stop:6,.0f}"

    text = Text()
    text.append(f"[{snapshot.id}] ")
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
# Terminal Renderer
# -----------------------------------------------------------------
class TerminalRenderer:
    """Transient Rich live region of unfinished runs, with final lines printed above it.

    The region exists only while runs are unfinished, and redraws only when
    ``ProgressDisplay`` asks, never on a timer of its own.
    """

    def __init__(self, console: Console | None = None) -> None:
        self.console: Console = console if console is not None else Console()
        self._live: Live | None = None

    def show(self, active: Sequence[SimulationSnapshot]) -> None:
        """Redraw the live region, starting it on demand and stopping it when empty."""
        if not active:
            self.close()
            return

        lines = Group(*(_render_line(snapshot) for snapshot in active))
        if self._live is None:
            live = Live(lines, console=self.console, auto_refresh=False, transient=True)
            live.start(refresh=True)
            self._live = live
        else:
            self._live.update(lines, refresh=True)

    def finished(self, snapshot: SimulationSnapshot) -> None:
        """Print a final line above the live region."""
        self.console.print(_render_line(snapshot))

    def close(self) -> None:
        """Stop and erase the live region; printed lines stay."""
        if self._live is not None:
            live, self._live = self._live, None
            live.stop()


# -----------------------------------------------------------------
# Notebook Renderer
# -----------------------------------------------------------------
class NotebookRenderer:
    """Notebook view with one live output area for unfinished runs.

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

    def show(self, active: Sequence[SimulationSnapshot]) -> None:
        """Replace the live output area, publishing it on first use."""
        if self._handle is None and not active:
            return

        html = self._render_html(active)
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

    def finished(self, snapshot: SimulationSnapshot) -> None:
        """Print a final line to stdout."""
        self._completed_console.print(_render_line(snapshot), soft_wrap=True)

    def close(self) -> None:
        """Release the handle without publishing."""
        self._handle = None
        self._last_html = None

    @staticmethod
    def _render_html(snapshots: Sequence[SimulationSnapshot]) -> str:
        """Export only the supplied snapshots as a Rich HTML fragment."""
        if not snapshots:
            return ""

        # A fresh, private console keeps frame buffers bounded and bypasses Rich's
        # Jupyter output hook; publishing is handled explicitly by the caller.
        console = Console(file=StringIO(), record=True, force_jupyter=False, color_system=None)
        console.print(Group(*(_render_line(snapshot) for snapshot in snapshots)), soft_wrap=True)
        return console.export_html(
            inline_styles=True,
            code_format=(
                '<pre style="margin:0;white-space:pre;overflow-x:auto;line-height:1.3;'
                'font-family:monospace;color:inherit;background:transparent">{code}</pre>'
            ),
        )


def _auto_renderer() -> Renderer:
    """Select the environment-appropriate renderer without eagerly importing IPython."""
    if _in_notebook_kernel():
        return NotebookRenderer()
    return TerminalRenderer()


# -----------------------------------------------------------------
# Progress Display
# -----------------------------------------------------------------
class ProgressDisplay:
    """Show live progress of a manager's runs from a background thread.

    Every `refresh_interval` seconds it picks up the manager's ``started``
    runs, those a daemon worker has accepted, prints each newly finished run
    once, and redraws the running ones. Queued runs are never read nor drawn,
    so a redraw costs at most ``max_concurrent`` lines however many runs
    wait. A run that is accepted and finishes
    between two redraws is never seen, so it gets no final line; its handle
    still holds the result. Rendering failures are logged and never affect
    the runs.

    It never asks the daemon itself: the handles it reads change when the
    manager updates them from its own background thread.

    ``SimulationManager`` creates and closes one by default; create your own
    only for a manager built with ``display=False``. Close it once done,
    usually by leaving a ``with ProgressDisplay(...)`` block. Closing prints
    only runs the daemon has already finished, clears
    the live rows, and stops following unfinished runs without changing
    their state.

    Parameters
    ----------
    manager : SimulationManager
        Manager whose runs to show.
    refresh_interval : float, optional
        Seconds between redraws. Must be positive.
    renderer : Renderer, optional
        Output surface; by default a notebook renderer inside a Jupyter
        kernel, otherwise a terminal renderer.
    """

    def __init__(
        self,
        manager: SimulationManager,
        *,
        refresh_interval: float = 1.0,
        renderer: Renderer | None = None,
    ) -> None:
        if not refresh_interval > 0:
            raise ValueError("refresh_interval must be positive")

        self._manager: SimulationManager = manager
        self._refresh_interval: float = refresh_interval
        self._renderer: Renderer = renderer if renderer is not None else _auto_renderer()
        self._lock: Lock = Lock()
        self._closed: bool = False
        # Accepted runs until printed finished; only the redraw thread, or `close` after it, uses them.
        self._rows: dict[int, Simulation] = {}
        self._stop: Event = Event()
        self._thread: Thread = Thread(target=self._run, name="trnrun-progress", daemon=True)
        self._thread.start()

    def close(self) -> None:
        """Stop following runs, print those already finished, and release the output."""
        with self._lock:
            if self._closed:
                return
            self._closed = True

        self._stop.set()
        if current_thread() is not self._thread:
            self._thread.join()
        self._tick()
        self._rows.clear()
        self._renderer.close()

    def __enter__(self) -> Self:
        """Return the running display."""
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Close the display when leaving the context."""
        self.close()

    def _run(self) -> None:
        """Redraw every refresh interval until closed."""
        while not self._stop.wait(self._refresh_interval):
            self._tick()

    def _tick(self) -> None:
        """Redraw once; a renderer failure is logged, never raised."""
        try:
            self._render()
        except Exception:
            logger.exception("TRNRun progress display failed to render")

    def _render(self) -> None:
        """Pick up newly started runs, print and drop finished ones, then show the unfinished ones."""
        # Only the started runs, never the whole queue, however many runs wait.
        for simulation in self._manager.started:
            _ = self._rows.setdefault(simulation.id, simulation)

        active: list[SimulationSnapshot] = []
        for simulation in list(self._rows.values()):
            snapshot = simulation.snapshot()
            if snapshot.is_finished:
                # Drop first, so a failing renderer cannot print the same run twice.
                del self._rows[snapshot.id]
                self._renderer.finished(snapshot)
            elif not self._closed:
                active.append(snapshot)
        self._renderer.show(active)
