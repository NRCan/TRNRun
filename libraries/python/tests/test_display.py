# ruff: noqa: S101, SLF001

from __future__ import annotations

import builtins
from dataclasses import dataclass
from html.parser import HTMLParser
from io import StringIO
from typing import override
from unittest.mock import Mock, call

import pytest
from rich.console import Console
from rich.live import Live
from rich.style import Style
from rich.text import Text

import trnrun.display as display_module
from trnrun.config import SimulationConfig
from trnrun.display import Display, NotebookDisplay, NullDisplay
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


@dataclass
class FakeHTML:
    """Minimal stand-in retaining rendered HTML for assertions."""

    data: str


class FakeDisplayHandle:
    """Record replacements made to one notebook output area."""

    def __init__(self, obj: FakeHTML) -> None:
        self.html = obj
        self.updates: list[FakeHTML] = []

    def update(self, obj: FakeHTML) -> None:
        """Record one output replacement."""
        self.html = obj
        self.updates.append(obj)


class ParsedHTML(HTMLParser):
    """Collect decoded text, elements, and inline spans from a Rich fragment."""

    def __init__(self, html: str) -> None:
        super().__init__()
        self.text: list[str] = []
        self.elements: list[tuple[str, dict[str, str | None]]] = []
        self.spans: list[tuple[str, str]] = []
        self._span_styles: list[str] = []
        self.feed(html)
        self.close()

    @override
    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        """Retain attributes and the current inline span style."""
        attributes = dict(attrs)
        self.elements.append((tag, attributes))
        if tag == "span":
            self._span_styles.append(attributes.get("style") or "")

    @override
    def handle_endtag(self, tag: str) -> None:
        """Leave the current span when its closing tag is reached."""
        if tag == "span":
            _ = self._span_styles.pop()

    @override
    def handle_data(self, data: str) -> None:
        """Retain whitespace and decoded entities for exact line comparisons."""
        self.text.append(data)
        if self._span_styles:
            self.spans.append((data, self._span_styles[-1]))

    @property
    def lines(self) -> list[str]:
        """Ignore only end padding, which Rich strips from rows wider than its console."""
        return [line.rstrip() for line in "".join(self.text).splitlines()]


@pytest.fixture
def notebook_api(monkeypatch: pytest.MonkeyPatch) -> tuple[Mock, list[FakeDisplayHandle]]:
    """Record the live display; completed lines must use stdout instead."""
    handles: list[FakeDisplayHandle] = []

    def publish(obj: FakeHTML, *, display_id: bool) -> FakeDisplayHandle:
        assert display_id is True
        handle = FakeDisplayHandle(obj)
        handles.append(handle)
        return handle

    display_html = Mock(side_effect=publish)
    monkeypatch.setattr(display_module, "_load_notebook_api", Mock(return_value=(FakeHTML, display_html)))
    return display_html, handles


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
    monkeypatch.setattr(display_module, "_render_line", render_line)
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
    assert render_line.call_args_list == [call(first), call(second)]
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
    assert display_module._progress_bar(percent, width) == expected


def test_render_line_shows_placeholders_without_runner_updates() -> None:
    """Pending simulations render stable placeholders for absent measurements."""
    line = display_module._render_line(make_simulation(sim_id=3))

    assert line.plain.startswith("[3] deck.dck")
    assert "Status:            │" in line.plain
    assert "Logs: N:0 W:0 F:0" in line.plain
    assert "Elapsed: --:--:-- │ ETA: --:--:--" in line.plain
    assert "[--------------------] - / -" in line.plain


def test_render_line_formats_complete_state_and_status_style() -> None:
    """Runner state is folded into counts, timing, progress, and status color."""
    simulation = make_simulation(sim_id=7, deck_path="models/annual-load.dck")
    simulation.apply_event(StatusEvent("DONE", TIMESTAMP))
    simulation.apply_event(ConfigEvent(0.0, 2_000.0, 1.0, TIMESTAMP))
    simulation.apply_event(ProgressEvent(1_234.0, 0.25, 3_723_000.0, 65_000.0, TIMESTAMP))
    for severity in ("Notice", "Warning", "Fatal"):
        simulation.apply_event(LogEvent(severity, TIMESTAMP))

    line = display_module._render_line(simulation)

    assert str(simulation.deck_path) in line.plain
    assert "Status: DONE" in line.plain
    assert "Logs: N:1 W:1 F:1" in line.plain
    assert "Elapsed: 01:02:03 │ ETA: 00:01:05" in line.plain
    assert "[#####---------------]  1,234 /  2,000 (25%)" in line.plain
    assert any(span.style == "green" and line.plain[span.start : span.end].strip() == "DONE" for span in line.spans)


def test_render_all_preserves_simulation_insertion_order(
    display_and_console: tuple[Display, Mock],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Stable active insertion order produces stable line ordering."""
    display, _ = display_and_console
    second = make_simulation(2, "second.dck")
    first = make_simulation(1, "first.dck")
    display._active = {2: second, 1: first}
    render_line = Mock(wraps=display_module._render_line)
    monkeypatch.setattr(display_module, "_render_line", render_line)

    rendered = list(display._render_all().renderables)
    rendered_lines = [line for line in rendered if isinstance(line, Text)]

    assert len(rendered_lines) == len(rendered)
    assert [line.plain.split(" ", maxsplit=1)[0] for line in rendered_lines] == ["[2]", "[1]"]
    assert render_line.call_args_list == [call(second), call(first)]


def test_auto_display_selects_notebook_for_active_kernel(monkeypatch: pytest.MonkeyPatch) -> None:
    """Auto mode recognizes Jupyter kernels, including VS Code's kernel shell."""
    shell = Mock()
    shell.kernel = object()
    monkeypatch.setattr(builtins, "get_ipython", lambda: shell, raising=False)
    notebook = Mock(spec=NotebookDisplay)
    notebook_factory = Mock(return_value=notebook)
    terminal_factory = Mock()
    monkeypatch.setattr(display_module, "NotebookDisplay", notebook_factory)
    monkeypatch.setattr(display_module, "Display", terminal_factory)

    selected = display_module.create_display(0.5)

    assert selected is notebook
    notebook_factory.assert_called_once_with(refresh_interval=0.5)
    terminal_factory.assert_not_called()


def test_auto_display_selects_terminal_without_kernel(monkeypatch: pytest.MonkeyPatch) -> None:
    """Auto mode keeps Rich in ordinary terminals without loading IPython."""
    monkeypatch.delattr(builtins, "get_ipython", raising=False)
    terminal = Mock(spec=Display)
    terminal_factory = Mock(return_value=terminal)
    notebook_loader = Mock()
    monkeypatch.setattr(display_module, "Display", terminal_factory)
    monkeypatch.setattr(display_module, "_load_notebook_api", notebook_loader)

    selected = display_module.create_display(0.5)

    assert selected is terminal
    terminal_factory.assert_called_once_with(refresh_interval=0.5)
    notebook_loader.assert_not_called()


def test_nonpositive_interval_selects_null_display(monkeypatch: pytest.MonkeyPatch) -> None:
    """Legacy nonpositive intervals remain headless without environment detection."""
    notebook_factory = Mock()
    terminal_factory = Mock()
    detect_kernel = Mock()
    monkeypatch.setattr(display_module, "NotebookDisplay", notebook_factory)
    monkeypatch.setattr(display_module, "Display", terminal_factory)
    monkeypatch.setattr(display_module, "_in_notebook_kernel", detect_kernel)

    assert isinstance(display_module.create_display(0.0), NullDisplay)

    detect_kernel.assert_not_called()
    notebook_factory.assert_not_called()
    terminal_factory.assert_not_called()


def test_notebook_display_throttles_progress_but_updates_lifecycle_promptly(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Starts and completions bypass throttling, while progress waits for its interval."""
    display_html, handles = notebook_api
    monotonic = Mock(side_effect=[10.0, 10.25, 10.5, 11.25, 11.5])
    monkeypatch.setattr(display_module.time, "monotonic", monotonic)
    display = NotebookDisplay(refresh_interval=1.0)
    simulation = make_simulation(1)
    second = make_simulation(2)

    display.simulation_started(simulation)
    handle = handles[0]
    display.simulation_started(second)
    assert len(handle.updates) == 1
    simulation.apply_event(ProgressEvent(100.0, 0.25, 500.0, 1_500.0, TIMESTAMP))
    display.refresh()
    assert len(handle.updates) == 1
    simulation.apply_event(ProgressEvent(200.0, 0.5, 1_000.0, 1_000.0, TIMESTAMP))
    display.refresh()
    simulation.apply_event(StatusEvent("DONE", TIMESTAMP))
    display.simulation_finished(simulation)

    display_html.assert_called_once()
    assert len(handles) == 1
    assert display_html.call_args.kwargs == {"display_id": True}
    captured = capsys.readouterr()
    assert captured.out == display_module._render_line(simulation).plain + "\n"
    assert captured.err == ""
    assert len(handle.updates) == 3
    assert "50%" in handle.updates[1].data
    assert ParsedHTML(handle.html.data).lines == [display_module._render_line(second).plain.rstrip()]
    assert display._handle is handle
    assert display._last_html == handle.html.data
    assert display._last_refresh == 11.5
    assert display._active == {2: second}


@pytest.mark.parametrize(
    "deck_path",
    ["deck.dck", "models/" + "long-directory/" * 8 + "annual-load.dck"],
    ids=["short-path", "long-path"],
)
def test_notebook_html_matches_terminal_lines_at_narrow_width(
    monkeypatch: pytest.MonkeyPatch,
    deck_path: str,
) -> None:
    """HTML preserves the shared row's spacing and tail instead of wrapping or cropping."""
    monkeypatch.setenv("COLUMNS", "20")
    simulation = make_simulation(7, deck_path)
    simulation.apply_event(StatusEvent("DONE", TIMESTAMP))
    simulation.apply_event(ConfigEvent(0.0, 2_000.0, 1.0, TIMESTAMP))
    simulation.apply_event(ProgressEvent(1_234.0, 0.25, 3_723_000.0, 65_000.0, TIMESTAMP))
    for severity in ("Notice", "Warning", "Fatal"):
        simulation.apply_event(LogEvent(severity, TIMESTAMP))
    pending = make_simulation(8)
    terminal = Display()
    terminal._active = {7: simulation, 8: pending}

    output = StringIO()
    console = Console(file=output, width=20, force_jupyter=False, color_system=None)
    console.print(terminal._render_all(), soft_wrap=True)
    expected = [display_module._render_line(sim).plain.rstrip() for sim in (simulation, pending)]
    render_line = Mock(wraps=display_module._render_line)
    monkeypatch.setattr(display_module, "_render_line", render_line)

    parsed = ParsedHTML(NotebookDisplay._render_html(iter((simulation, pending))))

    assert [line.rstrip() for line in output.getvalue().splitlines()] == expected
    assert parsed.lines == expected
    assert len(expected[0]) > console.width
    assert "[#####---------------]  1,234 /  2,000 (25%)" in expected[0]
    assert render_line.call_args_list == [call(simulation), call(pending)]


@pytest.mark.parametrize(
    ("status", "color"),
    [("DONE", "green"), ("ERROR", "red"), ("TIMEOUT", "red"), ("STALLED", "red"), ("CANCELLED", "yellow")],
)
def test_notebook_html_is_an_escaped_inline_styled_fragment(
    status: str,
    color: str,
) -> None:
    """Only status spans add color; notebook themes supply the fragment's base colors."""
    simulation = make_simulation(1, "deck<script>&.dck")
    simulation.apply_event(StatusEvent(status, TIMESTAMP))
    escaped_status = make_simulation(2)
    escaped_status.apply_event(StatusEvent('<script>alert("x")</script>&', TIMESTAMP))

    html = NotebookDisplay._render_html((simulation, escaped_status))
    parsed = ParsedHTML(html)

    expected = [display_module._render_line(sim).plain.rstrip() for sim in (simulation, escaped_status)]
    assert parsed.lines == expected
    assert "&lt;script&gt;" in html
    assert "&amp;" in html
    expected_style = Style.parse(color).get_html_style()
    assert any(text.strip() == status and expected_style in style for text, style in parsed.spans)
    tags = {tag for tag, _ in parsed.elements}
    assert not tags.intersection({"html", "head", "body", "style", "script", "table"})
    assert "<!doctype" not in html.lower()
    assert all(not name.startswith("on") for _, attrs in parsed.elements for name in attrs)
    assert "javascript:" not in html.lower()
    pre_styles = [attrs.get("style") or "" for tag, attrs in parsed.elements if tag == "pre"]
    assert len(pre_styles) == 1
    css = dict(declaration.strip().split(":", 1) for declaration in pre_styles[0].split(";") if declaration.strip())
    css = {name.strip(): value.strip() for name, value in css.items()}
    assert css["color"] == "inherit"
    assert css.get("background", css.get("background-color")) in {"inherit", "transparent"}
    assert css["white-space"] == "pre"
    assert css["overflow-x"] == "auto"
    assert css["line-height"] == "1.3"


def test_notebook_unchanged_refreshes_advance_throttle_without_publishing(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Unchanged frames advance the throttle; finishing prints once and empties live output."""
    display_html, handles = notebook_api
    monotonic = Mock(side_effect=[10.0, 11.0, 11.5, 12.0, 12.5, 13.0, 13.25])
    monkeypatch.setattr(display_module.time, "monotonic", monotonic)
    display = NotebookDisplay(refresh_interval=1.0)
    render_html = Mock(wraps=display._render_html)
    monkeypatch.setattr(display, "_render_html", render_html)
    simulation = make_simulation()
    display.simulation_started(simulation)
    handle = handles[0]
    initial_html = handle.html.data

    display.refresh()

    assert handle.updates == []
    assert display._last_html == initial_html
    assert display._last_refresh == 11.0
    assert render_html.call_count == 2

    simulation.apply_event(ProgressEvent(100.0, 0.25, 500.0, 1_500.0, TIMESTAMP))
    display.refresh()

    assert handle.updates == []
    assert display._last_refresh == 11.0
    assert render_html.call_count == 2

    display.refresh()

    assert len(handle.updates) == 1
    assert "25%" in handle.updates[0].data
    assert display._last_html == handle.updates[0].data
    assert display._last_refresh == 12.0
    assert render_html.call_count == 3

    display.refresh()
    assert render_html.call_count == 3
    display.refresh()
    assert render_html.call_count == 4
    assert display._last_refresh == 13.0
    display.simulation_finished(simulation)

    display_html.assert_called_once()
    assert capsys.readouterr().out == display_module._render_line(simulation).plain + "\n"
    assert len(handles) == 1
    assert len(handle.updates) == 2
    assert handle.html.data == ""
    assert render_html.call_count == 5
    assert display._handle is handle
    assert display._last_html == ""
    assert display._last_refresh == 13.25
    assert display._active == {}

    monotonic.reset_mock()
    render_html.reset_mock()
    display.refresh()
    monotonic.assert_not_called()
    render_html.assert_not_called()


def test_notebook_renders_use_fresh_silent_recording_consoles(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Repeated exports contain only current state and never print to either stream."""
    console_factory = Mock(wraps=Console)
    monkeypatch.setattr(display_module, "Console", console_factory)
    simulation = make_simulation()
    simulation.apply_event(StatusEvent("RUNNING", TIMESTAMP))

    old_html = NotebookDisplay._render_html((simulation,))
    simulation.apply_event(StatusEvent("DONE", TIMESTAMP))
    new_html = NotebookDisplay._render_html((simulation,))
    repeated_html = NotebookDisplay._render_html((simulation,))

    assert "RUNNING" in old_html
    assert "RUNNING" not in new_html
    assert ParsedHTML(new_html).lines == [display_module._render_line(simulation).plain.rstrip()]
    assert repeated_html == new_html
    assert console_factory.call_count == 3
    buffers: list[StringIO] = []
    for invocation in console_factory.call_args_list:
        assert isinstance(invocation.kwargs["file"], StringIO)
        assert invocation.kwargs["record"] is True
        assert invocation.kwargs["force_jupyter"] is False
        assert invocation.kwargs["color_system"] is None
        buffers.append(invocation.kwargs["file"])
    assert len({id(buffer) for buffer in buffers}) == 3
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err == ""


def test_notebook_progress_renders_only_five_active_after_one_hundred_completions(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Completed runs are printed once, not revisited by active progress refreshes."""
    display_html, handles = notebook_api
    display = NotebookDisplay(refresh_interval=1.0)
    completed = [make_simulation(sim_id, f"completed-{sim_id}.dck") for sim_id in range(1, 101)]
    render_line = Mock(wraps=display_module._render_line)
    monkeypatch.setattr(display_module, "_render_line", render_line)

    for simulation in completed:
        display.simulation_started(simulation)
        simulation.apply_event(StatusEvent("DONE", TIMESTAMP))
        render_line.reset_mock()
        display.simulation_finished(simulation)
        render_line.assert_called_once_with(simulation)

    assert len(handles) == 1
    display_html.assert_called_once()
    assert display_html.call_args.kwargs == {"display_id": True}
    captured = capsys.readouterr()
    assert captured.out == "".join(display_module._render_line(simulation).plain + "\n" for simulation in completed)
    assert captured.err == ""

    active = [make_simulation(sim_id, f"active-{sim_id}.dck") for sim_id in range(101, 106)]
    for simulation in active:
        display.simulation_started(simulation)
    active[0].apply_event(ProgressEvent(50.0, 0.5, 1_000.0, 1_000.0, TIMESTAMP))
    render_line.reset_mock()
    export_html = Mock(wraps=Console.export_html)

    def record_export(console: Console, **kwargs: object) -> str:
        return export_html(console, **kwargs)

    monkeypatch.setattr(Console, "export_html", record_export)
    monkeypatch.setattr(display_module.time, "monotonic", lambda: display._last_refresh + 1.0)
    updates_before = len(handles[0].updates)

    display.refresh()

    assert render_line.call_args_list == [call(simulation) for simulation in active]
    assert export_html.call_count == 1
    display_html.assert_called_once()
    assert len(handles) == 1
    assert len(handles[0].updates) == updates_before + 1
    assert len(ParsedHTML(handles[0].html.data).lines) == 5
    assert "completed-" not in handles[0].html.data
    assert capsys.readouterr().out == ""
    assert display._active == {simulation.id: simulation for simulation in active}


def test_notebook_reuses_live_handle_and_preserves_completed_output(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Completed lines are plain text and never reprinted when later batches start."""
    display_html, handles = notebook_api
    display = NotebookDisplay()
    simulation = make_simulation(1, "first<script>&.dck")
    display.simulation_started(simulation)
    handle = handles[0]
    simulation.apply_event(StatusEvent("DONE", TIMESTAMP))
    display.simulation_finished(simulation)

    assert handle.html.data == ""
    captured = capsys.readouterr()
    assert captured.out == display_module._render_line(simulation).plain + "\n"
    assert "first<script>&.dck" in captured.out
    assert "\x1b" not in captured.out
    assert captured.err == ""
    display_html.assert_called_once()
    simulation.apply_event(StatusEvent("ERROR", TIMESTAMP))
    second = make_simulation(2)
    display.simulation_started(second)

    assert handles == [handle]
    assert display._handle is handle
    display_html.assert_called_once()
    assert ParsedHTML(handle.html.data).lines == [display_module._render_line(second).plain.rstrip()]
    assert capsys.readouterr().out == ""

    second.apply_event(StatusEvent("DONE", TIMESTAMP))
    display.simulation_finished(second)
    display_html.assert_called_once()
    assert capsys.readouterr().out == display_module._render_line(second).plain + "\n"
    assert handle.html.data == ""
    assert display._active == {}
    monotonic = Mock()
    monkeypatch.setattr(display_module.time, "monotonic", monotonic)
    display.refresh()
    monotonic.assert_not_called()


def test_notebook_empty_render_does_not_export_a_blank_line(monkeypatch: pytest.MonkeyPatch) -> None:
    """Empty active output is truly empty and needs no Rich console."""
    console_factory = Mock()
    monkeypatch.setattr(display_module, "Console", console_factory)

    assert NotebookDisplay._render_html(()) == ""

    console_factory.assert_not_called()
