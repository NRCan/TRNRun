"""Terminal display for TRNRun-manager simulations using Rich.

Provides live terminal output for running simulations and prints final
results when they complete. The display does not own simulation state; it
only renders the state provided by ``SimulationManager``.
"""

# pyright: reportUnusedCallResult=false

from __future__ import annotations

from threading import Lock

from rich.console import Console, Group
from rich.live import Live
from rich.text import Text

from trnrun.simulation import Simulation, SimulationSnapshot
from trnrun.utils import format_hhmmss, truncate_left

# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
COLOR_MAP: dict[str, str | None] = {
    "PENDING": None,
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


# -----------------------------------------------------------------
# Null Display
# -----------------------------------------------------------------
class NullDisplay:
    """Display that renders nothing; for headless runs and tests."""

    def simulation_started(self, _simulation: Simulation) -> None:
        """Ignore simulation start events."""

    def simulation_finished(self, _simulation: Simulation) -> None:
        """Ignore simulation finish events."""


# -----------------------------------------------------------------
# Display
# -----------------------------------------------------------------
class Display:
    """Live terminal view of currently running simulations.

    Parameters
    ----------
    refresh_interval : float, optional
        Time in seconds between live region refreshes. Must be positive.
    """

    def __init__(self, refresh_interval: float = 1.0) -> None:
        if refresh_interval <= 0:
            raise ValueError("refresh_interval must be positive")

        self.console: Console = Console()

        self._lock: Lock = Lock()
        self._live_lock: Lock = Lock()

        self._active: dict[int, Simulation] = {}
        self._refresh_per_second: float = 1 / refresh_interval
        self._live: Live | None = None

    # -----------------------------------------------------------------
    # Event Handlers
    # -----------------------------------------------------------------
    def simulation_started(self, simulation: Simulation) -> None:
        """Add a simulation to the live display."""
        with self._live_lock:
            with self._lock:
                self._active[simulation.id] = simulation

            if self._live is None:
                live = self._make_live()
                live.start()
                self._live = live

    def simulation_finished(self, simulation: Simulation) -> None:
        """Remove a simulation and print its final state."""
        with self._live_lock:
            with self._lock:
                self._active.pop(simulation.id, None)
                empty = not self._active

            self.console.print(self._render_line(simulation.snapshot()))

            if empty and self._live is not None:
                live, self._live = self._live, None
                live.stop()

    # -----------------------------------------------------------------
    # Rendering
    # -----------------------------------------------------------------
    def _make_live(self) -> Live:
        """Build a fresh transient live display."""
        return Live(
            get_renderable=self._render_all,
            console=self.console,
            refresh_per_second=self._refresh_per_second,
            transient=True,
        )

    def _progress_bar(self, percent: float, width: int = PROGRESS_BAR_WIDTH) -> str:
        """Return a fixed-width ASCII completion bar."""
        filled = min(max(int(width * percent), 0), width)
        return "[" + "#" * filled + "-" * (width - filled) + "]"

    def _render_line(self, sim: SimulationSnapshot) -> Text:
        """Render one simulation snapshot."""
        path = truncate_left(str(sim.deck_path), PATH_WIDTH)

        status = sim.status.status if sim.status else "PENDING"
        status_style = COLOR_MAP.get(status.upper())

        logs = f"N:{sim.notices} W:{sim.warnings} F:{sim.fatals}"

        progress = sim.progress

        elapsed = format_hhmmss(progress.elapsed / MS_PER_SECOND if progress else None)
        eta = format_hhmmss(progress.eta / MS_PER_SECOND if progress else None)

        sim_time = progress.time if progress else None
        percent = progress.percent if progress else None

        config = sim.config_event
        sim_stop = config.stop if config else None

        if percent is None:
            bar = "[" + "-" * PROGRESS_BAR_WIDTH + "]"
            sim_percent = ""
        else:
            bar = self._progress_bar(percent)
            sim_percent = f"({percent * 100:.0f}%)"

        sim_progress = "- / -" if sim_time is None or sim_stop is None else f"{sim_time:6,.0f} / {sim_stop:6,.0f}"

        text = Text()
        text.append(f"[{sim.id}] ")
        text.append(f"{path:<{PATH_WIDTH}} │ ")
        text.append("Status: ")
        text.append(f"{status:<10}", style=status_style)
        text.append(" │ ")
        text.append(f"Logs: {logs:<12} │ ")
        text.append(f"Elapsed: {elapsed:<8} │ ETA: {eta:<8} │ ")
        text.append(f"{bar} {sim_progress} {sim_percent:6}")

        if sim.error is not None:
            text.append(f" │ error: {sim.error}", style="red")

        return text

    def _render_all(self) -> Group:
        """Render all active simulations."""
        with self._lock:
            active = list(self._active.values())

        return Group(*(self._render_line(sim.snapshot()) for sim in active))
