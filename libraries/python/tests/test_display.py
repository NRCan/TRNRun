# ruff: noqa: S101, SLF001

from __future__ import annotations

from unittest.mock import Mock

import pytest
from rich.console import Console
from rich.live import Live
from rich.text import Text

import trnrun.display as display_module
from trnrun.config import SimulationConfig
from trnrun.display import Display, NullDisplay
from trnrun.events import ConfigEvent, LogEvent, ProgressEvent, StatusEvent
from trnrun.simulation import Simulation

TIMESTAMP = "2026-01-02T03:04:05Z"


@pytest.fixture
def display_and_console(monkeypatch: pytest.MonkeyPatch) -> tuple[Display, Mock]:
    """Build a display without constructing a terminal console."""
    console = Mock(spec=Console)
    monkeypatch.setattr(display_module, "Console", Mock(return_value=console))
    return Display(refresh_interval=1.0), console


def make_simulation(sim_id: int = 1, deck_path: str = "deck.dck") -> Simulation:
    """Build an unvalidated simulation for rendering tests."""
    return Simulation(deck_path, SimulationConfig(), sim_id)


@pytest.mark.parametrize("refresh_interval", [0.0, -0.01])
def test_display_rejects_nonpositive_refresh_intervals(refresh_interval: float) -> None:
    """Live refresh throttling requires a positive interval."""
    with pytest.raises(ValueError, match="refresh_interval must be positive"):
        Display(refresh_interval)


def test_null_display_ignores_all_notifications() -> None:
    """The headless display accepts the complete manager callback surface."""
    display = NullDisplay()
    simulation = make_simulation()

    assert display.simulation_started(simulation) is None
    assert display.refresh() is None
    assert display.simulation_finished(simulation) is None


def test_starting_simulations_creates_and_starts_one_live_region(
    display_and_console: tuple[Display, Mock],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The first active simulation owns the sole live region."""
    display, _ = display_and_console
    live = Mock(spec=Live)
    make_live = Mock(return_value=live)
    monkeypatch.setattr(display, "_make_live", make_live)
    first = make_simulation(1)
    second = make_simulation(2)

    display.simulation_started(first)
    display.simulation_started(second)

    assert display._active == {1: first, 2: second}
    assert display._live is live
    make_live.assert_called_once_with()
    live.start.assert_called_once_with()


def test_finishing_prints_each_result_and_stops_live_after_last_simulation(
    display_and_console: tuple[Display, Mock],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Final lines print outside the live region before its final shutdown."""
    display, console = display_and_console
    live = Mock(spec=Live)
    rendered_first = Text("first result")
    rendered_second = Text("second result")
    monkeypatch.setattr(display, "_make_live", Mock(return_value=live))
    render_line = Mock(side_effect=[rendered_first, rendered_second])
    monkeypatch.setattr(display, "_render_line", render_line)
    first = make_simulation(1)
    second = make_simulation(2)
    display.simulation_started(first)
    display.simulation_started(second)

    display.simulation_finished(first)

    assert display._active == {2: second}
    assert display._live is live
    live.stop.assert_not_called()

    display.simulation_finished(second)

    assert display._active == {}
    assert display._live is None
    assert console.print.call_args_list[0].args == (rendered_first,)
    assert console.print.call_args_list[1].args == (rendered_second,)
    live.stop.assert_called_once_with()


def test_refresh_is_noop_without_live_region(
    display_and_console: tuple[Display, Mock],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """An idle display does not even read the monotonic clock."""
    display, _ = display_and_console
    monotonic = Mock()
    monkeypatch.setattr(display_module.time, "monotonic", monotonic)

    display.refresh()

    monotonic.assert_not_called()


def test_refresh_uses_monotonic_interval_throttling(
    display_and_console: tuple[Display, Mock],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Refreshes occur at the boundary and update the throttle timestamp."""
    display, _ = display_and_console
    live = Mock(spec=Live)
    display._live = live
    monkeypatch.setattr(display_module.time, "monotonic", Mock(side_effect=[0.5, 1.0, 1.5, 2.1]))

    for _ in range(4):
        display.refresh()

    assert live.refresh.call_count == 2
    assert display._last_refresh == 2.1


def test_make_live_disables_automatic_refresh(
    display_and_console: tuple[Display, Mock],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """The manager, rather than Rich, controls live redraw timing."""
    display, console = display_and_console
    live = Mock(spec=Live)
    live_factory = Mock(return_value=live)
    monkeypatch.setattr(display_module, "Live", live_factory)

    result = display._make_live()

    assert result is live
    live_factory.assert_called_once_with(
        get_renderable=display._render_all,
        console=console,
        auto_refresh=False,
        transient=True,
    )


@pytest.mark.parametrize(
    ("percent", "width", "expected"),
    [
        (-0.5, 4, "[----]"),
        (0.0, 4, "[----]"),
        (0.49, 4, "[#---]"),
        (0.5, 4, "[##--]"),
        (1.0, 4, "[####]"),
        (1.5, 4, "[####]"),
        (0.5, 0, "[]"),
    ],
)
def test_progress_bar_is_fixed_width_and_clamped(percent: float, width: int, expected: str) -> None:
    """Progress bars truncate fractional cells and clamp both endpoints."""
    assert Display._progress_bar(percent, width) == expected


def test_render_line_shows_placeholders_without_runner_updates(display_and_console: tuple[Display, Mock]) -> None:
    """Pending simulations render stable placeholders for absent measurements."""
    display, _ = display_and_console

    line = display._render_line(make_simulation(sim_id=3))

    assert line.plain.startswith("[3] deck.dck")
    assert "Status:            │" in line.plain
    assert "Logs: N:0 W:0 F:0" in line.plain
    assert "Elapsed: --:--:-- │ ETA: --:--:--" in line.plain
    assert "[--------------------] - / -" in line.plain


def test_render_line_formats_complete_state_and_status_style(display_and_console: tuple[Display, Mock]) -> None:
    """Runner state is folded into counts, timing, progress, and status color."""
    display, _ = display_and_console
    simulation = make_simulation(sim_id=7, deck_path="models/annual-load.dck")
    simulation.apply_event(StatusEvent("DONE", TIMESTAMP))
    simulation.apply_event(ConfigEvent(0.0, 2_000.0, 1.0, TIMESTAMP))
    simulation.apply_event(ProgressEvent(1_234.0, 0.25, 3_723_000.0, 65_000.0, TIMESTAMP))
    for severity in ("Notice", "Warning", "Fatal"):
        simulation.apply_event(LogEvent(severity, TIMESTAMP))

    line = display._render_line(simulation)

    assert str(simulation.deck_path) in line.plain
    assert "Status: DONE" in line.plain
    assert "Logs: N:1 W:1 F:1" in line.plain
    assert "Elapsed: 01:02:03 │ ETA: 00:01:05" in line.plain
    assert "[#####---------------]  1,234 /  2,000 (25%)" in line.plain
    assert any(span.style == "green" and line.plain[span.start : span.end].strip() == "DONE" for span in line.spans)


def test_render_all_preserves_simulation_insertion_order(display_and_console: tuple[Display, Mock]) -> None:
    """Stable active insertion order produces stable line ordering."""
    display, _ = display_and_console
    second = make_simulation(2, "second.dck")
    first = make_simulation(1, "first.dck")
    display._active = {2: second, 1: first}

    rendered = list(display._render_all().renderables)
    rendered_lines = [line for line in rendered if isinstance(line, Text)]

    assert len(rendered_lines) == len(rendered)
    assert [line.plain.split(" ", maxsplit=1)[0] for line in rendered_lines] == ["[2]", "[1]"]
