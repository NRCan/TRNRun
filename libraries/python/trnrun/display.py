"""Progress displays for TRNRun-manager simulations.

Rich renders the same status lines for terminals and notebooks. IPython
``DisplayHandle`` replaces notebook output in place without widgets or clearing
other cell output. Displays do not own simulation state; they
only render state provided synchronously by ``SimulationManager``.
"""

# pyright: reportUnusedCallResult=false

from __future__ import annotations

import builtins
import time
from collections.abc import Callable, Iterable
from io import StringIO
from typing import Protocol, cast

from rich.console import Console, Group
from rich.live import Live
from rich.text import Text

from trnrun.simulation import Simulation
from trnrun.utils import format_hhmmss, truncate_left

# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
COLOR_MAP: dict[str, str | None] = {
    "PENDING": None,
    "LAUNCHING": None,
    "RUNNING": None,
    "DONE": "green",
    "ERROR": "red",
    "TIMEOUT": "red",
    "STALLED": "red",
    "CANCELLED": "yellow",
}

PATH_WIDTH = 32
PROGRESS_BAR_WIDTH = 20
MS_PER_SECOND = 1000


class DisplayCallback(Protocol):
    """Callback surface used by ``SimulationManager``."""

    def simulation_started(self, simulation: Simulation) -> None:
        """Show a newly accepted simulation."""

    def simulation_finished(self, simulation: Simulation) -> None:
        """Show a completed simulation."""

    def refresh(self) -> None:
        """Refresh changed simulation state when due."""


class _DisplayHandle(Protocol):
    """Subset of an IPython ``DisplayHandle`` used by the notebook display."""

    def update(self, obj: object) -> None:
        """Replace the existing output with ``obj``."""


# -----------------------------------------------------------------
# Shared rendering helpers
# -----------------------------------------------------------------
def _progress_bar(percent: float, width: int = PROGRESS_BAR_WIDTH) -> str:
    """Return a fixed-width ASCII completion bar."""
    filled = min(max(int(width * percent), 0), width)
    return "[" + "#" * filled + "-" * (width - filled) + "]"


def _render_line(sim: Simulation) -> Text:
    """Render one simulation as a shared Rich status line."""
    path = truncate_left(str(sim.deck_path), PATH_WIDTH)

    status = sim.status.status if sim.status is not None else ""
    status_style = COLOR_MAP.get(status.upper())

    logs = f"N:{sim.notices} W:{sim.warnings} F:{sim.fatals}"

    progress = sim.progress

    elapsed = format_hhmmss(progress.elapsed / MS_PER_SECOND if progress else None)
    eta = format_hhmmss(progress.eta / MS_PER_SECOND if progress else None)

    sim_time = progress.time if progress else None
    percent = progress.percent if progress else None

    config = sim.config_event
    sim_stop = config.stop if config else None

    bar = _progress_bar(percent if percent is not None else 0.0)
    sim_percent = "" if percent is None else f"({percent * 100:.0f}%)"

    sim_progress = "- / -" if sim_time is None or sim_stop is None else f"{sim_time:6,.0f} / {sim_stop:6,.0f}"

    text = Text()
    text.append(f"[{sim.id}] ")
    text.append(f"{path} │ ")
    text.append("Status: ")
    text.append(f"{status:<10}", style=status_style)
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
        from IPython.display import HTML, display  # pyright: ignore[reportUnknownVariableType]
    except ImportError as error:
        raise ImportError("Notebook display mode requires IPython") from error
    return cast("Callable[[str], object]", HTML), cast("Callable[..., object]", display)


# -----------------------------------------------------------------
# Null Display
# -----------------------------------------------------------------
class NullDisplay:
    """Display that renders nothing; for headless runs and tests."""

    def simulation_started(self, simulation: Simulation) -> None:
        """Ignore simulation start events."""
        del simulation

    def simulation_finished(self, simulation: Simulation) -> None:
        """Ignore simulation finish events."""
        del simulation

    def refresh(self) -> None:
        """Ignore refresh requests."""


# -----------------------------------------------------------------
# Terminal Display
# -----------------------------------------------------------------
class Display:
    """Live terminal view of currently running simulations.

    The manager drives every redraw from its own thread, so the live region
    never refreshes on a timer of its own and never reads a simulation while
    the manager is updating it.

    Parameters
    ----------
    refresh_interval : float, optional
        Minimum time in seconds between live region redraws. Must be positive.
    """

    def __init__(self, refresh_interval: float = 1.0) -> None:
        if refresh_interval <= 0:
            raise ValueError("refresh_interval must be positive")

        self.console: Console = Console()

        self._active: dict[int, Simulation] = {}
        self._refresh_interval: float = refresh_interval
        self._last_refresh: float = 0.0
        self._live: Live | None = None

    # -----------------------------------------------------------------
    # Event Handlers
    # -----------------------------------------------------------------
    def simulation_started(self, simulation: Simulation) -> None:
        """Add a simulation to the live display."""
        self._active[simulation.id] = simulation

        if self._live is None:
            live = self._make_live()
            live.start()
            self._live = live

    def simulation_finished(self, simulation: Simulation) -> None:
        """Remove a simulation and print its final state."""
        _ = self._active.pop(simulation.id, None)

        self.console.print(_render_line(simulation))

        if not self._active and self._live is not None:
            live, self._live = self._live, None
            live.stop()

    def refresh(self) -> None:
        """Redraw the live region, at most once per refresh interval."""
        if self._live is None:
            return

        now = time.monotonic()
        if now - self._last_refresh < self._refresh_interval:
            return

        self._last_refresh = now
        self._live.refresh()

    # -----------------------------------------------------------------
    # Rendering
    # -----------------------------------------------------------------
    def _make_live(self) -> Live:
        """Build a fresh transient live display the manager refreshes itself."""
        return Live(
            get_renderable=self._render_all,
            console=self.console,
            auto_refresh=False,
            transient=True,
        )

    def _render_all(self) -> Group:
        """Render all active simulations."""
        return Group(*(_render_line(sim) for sim in self._active.values()))


# -----------------------------------------------------------------
# Notebook Display
# -----------------------------------------------------------------
class NotebookDisplay:
    """Notebook view with one live region for active simulations.

    Each completed result is printed once to stdout with ANSI status colours,
    never included in subsequent refreshes. Starts and
    completions update immediately; ordinary updates are throttled by
    ``refresh_interval`` and unchanged frames are not published. Rich exports
    unwrapped status lines as HTML without widgets.
    """

    def __init__(self, refresh_interval: float = 1.0) -> None:
        if refresh_interval <= 0:
            raise ValueError("refresh_interval must be positive")

        html, display_html = _load_notebook_api()
        self._html: Callable[[str], object] = html
        self._display_html: Callable[..., object] = display_html
        self._completed_console: Console = Console(
            force_jupyter=False,
            force_terminal=True,
            color_system="standard",
        )
        self._active: dict[int, Simulation] = {}

        self._refresh_interval: float = refresh_interval
        self._last_refresh: float = 0.0
        self._handle: _DisplayHandle | None = None
        self._last_html: str | None = None

    def simulation_started(self, simulation: Simulation) -> None:
        """Add a simulation and show it immediately."""
        self._active[simulation.id] = simulation
        self._update()

    def simulation_finished(self, simulation: Simulation) -> None:
        """Print a final line to stdout, then remove it from the live region."""
        _ = self._active.pop(simulation.id, None)
        self._completed_console.print(_render_line(simulation), soft_wrap=True)
        self._update()

    def refresh(self) -> None:
        """Update active progress at most once per refresh interval."""
        if not self._active:
            return

        now = time.monotonic()
        if now - self._last_refresh < self._refresh_interval:
            return
        self._update(now)

    def _update(self, now: float | None = None) -> None:
        """Replace only active output, leaving completed output untouched."""
        if self._handle is None and not self._active:
            return

        html = self._render_html(self._active.values())
        if html != self._last_html:
            rendered = self._html(html)
            if self._handle is None:
                handle = self._display_html(rendered, display_id=True)
                if handle is None or not hasattr(handle, "update"):
                    raise RuntimeError("IPython did not return a display handle")
                self._handle = cast("_DisplayHandle", handle)
            else:
                self._handle.update(rendered)
            self._last_html = html
        self._last_refresh = time.monotonic() if now is None else now

    @staticmethod
    def _render_html(simulations: Iterable[Simulation]) -> str:
        """Export only the supplied simulations as a Rich HTML fragment."""
        lines = [_render_line(simulation) for simulation in simulations]
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


def create_display(refresh_interval: float) -> DisplayCallback:
    """Select the environment-appropriate display without eagerly importing IPython."""
    if refresh_interval <= 0:
        return NullDisplay()
    if _in_notebook_kernel():
        return NotebookDisplay(refresh_interval=refresh_interval)
    return Display(refresh_interval=refresh_interval)
