# ruff: noqa: S101, SLF001

from __future__ import annotations

import builtins
from dataclasses import dataclass, replace
from html.parser import HTMLParser
from io import StringIO
from typing import override
from unittest.mock import Mock, call

import pytest
from rich.console import Console, Group
from rich.live import Live
from rich.style import Style
from rich.text import Text

import trnrun.convenience.display as display_module
from trnrun.config import SimulationConfig
from trnrun.convenience.display import ProgressDisplay
from trnrun.convenience.simulation import Simulation
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SimulationReply,
    SimulationState,
    SimulationStatus,
    StatusEvent,
)

TerminalOutput = display_module._TerminalOutput
NotebookOutput = display_module._NotebookOutput
render_line = display_module._render_line


def make_simulation(sim_id: int = 1, deck_path: str = "deck.dck") -> Simulation:
    """Build an unvalidated simulation for rendering tests."""
    return Simulation(deck_path, SimulationConfig(), sim_id)


def lines(*simulations: Simulation) -> list[Text]:
    """Render simulations as the display hands them to its output."""
    return [render_line(simulation) for simulation in simulations]


def apply_event(simulation: Simulation, event: StatusEvent | ConfigEvent | ProgressEvent | LogEvent) -> None:
    """Fold one runner event into a running simulation, as a daemon poll would."""
    current = SimulationReply(
        SimulationState.RUNNING,
        status=simulation.status_event,
        config=simulation.config_event,
        progress=simulation.progress,
        notices=simulation.notices,
        warnings=simulation.warnings,
        fatals=simulation.fatals,
    )
    if isinstance(event, LogEvent):
        counter = event.severity.lower() + "s"
        _ = simulation.apply(replace(current, **{counter: getattr(current, counter) + 1}, logs=(event,)))
    elif isinstance(event, StatusEvent):
        _ = simulation.apply(replace(current, status=event))
    elif isinstance(event, ConfigEvent):
        _ = simulation.apply(replace(current, config=event))
    else:
        _ = simulation.apply(replace(current, progress=event))


def finish(simulation: Simulation, status: SimulationStatus = SimulationStatus.DONE) -> None:
    """Finish a simulation as a finished daemon simulation would."""
    _ = simulation.apply(
        SimulationReply(
            SimulationState.FINISHED,
            exit_code=0,
            succeeded=status is SimulationStatus.DONE,
            status=StatusEvent(status),
        ),
    )


def completed_simulation() -> Simulation:
    """Return a fully reported, completed run."""
    simulation = make_simulation(sim_id=7, deck_path="models/annual-load.dck")
    apply_event(simulation, StatusEvent(SimulationStatus.DONE))
    apply_event(simulation, ConfigEvent(0.0, 2_000.0, 1.0))
    apply_event(simulation, ProgressEvent(1_234.0, 0.25, 3_723_000.0, 65_000.0))
    for severity in ("Notice", "Warning", "Fatal"):
        apply_event(simulation, LogEvent(severity))
    return simulation


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
    """Record the live output area; final lines must use stdout instead."""
    handles: list[FakeDisplayHandle] = []

    def publish(obj: FakeHTML, *, display_id: bool) -> FakeDisplayHandle:
        assert display_id is True
        handle = FakeDisplayHandle(obj)
        handles.append(handle)
        return handle

    display_html = Mock(side_effect=publish)
    monkeypatch.setattr(display_module, "_load_notebook_api", Mock(return_value=(FakeHTML, display_html)))
    return display_html, handles


# -----------------------------------------------------------------
# Shared rendering
# -----------------------------------------------------------------
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
    line = render_line(make_simulation(sim_id=3))

    assert line.plain.startswith("[3] deck.dck")
    assert "Status:            │" in line.plain
    assert "Logs: N:0 W:0 F:0" in line.plain
    assert "Elapsed: --:--:-- │ ETA: --:--:--" in line.plain
    assert "[--------------------] - / -" in line.plain


def test_color_map_covers_every_simulation_status() -> None:
    """Every native status has one explicit terminal and notebook display style."""
    assert all(isinstance(status, SimulationStatus) for status in display_module.COLOR_MAP)
    assert display_module.COLOR_MAP == {
        SimulationStatus.PENDING: None,
        SimulationStatus.LAUNCHING: None,
        SimulationStatus.RUNNING: None,
        SimulationStatus.DONE: "green",
        SimulationStatus.ERROR: "red",
        SimulationStatus.TIMEOUT: "red",
        SimulationStatus.STALLED: "red",
        SimulationStatus.CANCELLED: "yellow",
    }


def test_render_line_formats_complete_state_and_status_style() -> None:
    """Runner state is folded into counts, timing, progress, and status color."""
    simulation = completed_simulation()

    line = render_line(simulation)

    assert str(simulation.deck_path) in line.plain
    assert "Status: DONE" in line.plain
    assert "Logs: N:1 W:1 F:1" in line.plain
    assert "Elapsed: 01:02:03 │ ETA: 00:01:05" in line.plain
    assert "[#####---------------]  1,234 /  2,000 (25%)" in line.plain
    assert any(span.style == "green" and line.plain[span.start : span.end].strip() == "DONE" for span in line.spans)


# -----------------------------------------------------------------
# Terminal output
# -----------------------------------------------------------------
@pytest.fixture
def terminal(monkeypatch: pytest.MonkeyPatch) -> tuple[TerminalOutput, Mock, Mock]:
    """Build a terminal output whose console and live regions are mocks."""
    console = Mock(spec=Console)
    live_factory = Mock(side_effect=lambda *_args, **_kwargs: Mock(spec=Live))
    monkeypatch.setattr(display_module, "Live", live_factory)
    return TerminalOutput(console), console, live_factory


def test_terminal_show_starts_one_manually_refreshed_live_region(
    terminal: tuple[TerminalOutput, Mock, Mock],
) -> None:
    """The first rows start a transient region; later rows update it in place."""
    output, console, live_factory = terminal
    first, second = make_simulation(1), make_simulation(2)

    output.show(lines(first))
    output.show(lines(first, second))

    live_factory.assert_called_once()
    assert live_factory.call_args.kwargs == {"console": console, "auto_refresh": False, "transient": True}
    live = output._live
    assert isinstance(live, Mock)
    live.start.assert_called_once_with(refresh=True)
    (group,), kwargs = live.update.call_args
    assert kwargs == {"refresh": True}
    assert isinstance(group, Group)
    assert [line.plain.split(" ", maxsplit=1)[0] for line in group.renderables if isinstance(line, Text)] == [
        "[1]",
        "[2]",
    ]


def test_terminal_show_without_rows_stops_the_region(terminal: tuple[TerminalOutput, Mock, Mock]) -> None:
    """An empty frame erases the region, and later rows start a fresh one."""
    output, _, live_factory = terminal
    output.show([])
    live_factory.assert_not_called()

    output.show(lines(make_simulation()))
    live = output._live
    assert isinstance(live, Mock)
    output.show([])

    live.stop.assert_called_once_with()
    assert output._live is None
    output.show(lines(make_simulation()))
    assert live_factory.call_count == 2


def test_terminal_print_writes_the_final_line(terminal: tuple[TerminalOutput, Mock, Mock]) -> None:
    """Final lines go through the console, above any live region."""
    output, console, _ = terminal
    simulation = completed_simulation()

    output.print(render_line(simulation))

    (printed,) = console.print.call_args.args
    assert printed.plain == render_line(simulation).plain


def test_terminal_close_is_idempotent(terminal: tuple[TerminalOutput, Mock, Mock]) -> None:
    """Closing stops the region once and prints nothing."""
    output, console, _ = terminal
    output.show(lines(make_simulation()))
    live = output._live
    assert isinstance(live, Mock)

    output.close()
    output.close()

    live.stop.assert_called_once_with()
    console.print.assert_not_called()


# -----------------------------------------------------------------
# Notebook output
# -----------------------------------------------------------------
def test_notebook_show_publishes_once_then_replaces_only_changed_frames(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
) -> None:
    """One output area is reused; identical frames are not republished; empty frames clear it."""
    display_html, handles = notebook_api
    output = NotebookOutput()
    simulation = make_simulation(1)
    second = make_simulation(2)

    output.show([])
    display_html.assert_not_called()

    output.show(lines(simulation, second))
    (handle,) = handles
    output.show(lines(simulation, second))
    assert handle.updates == []

    apply_event(simulation, ProgressEvent(100.0, 0.5, 500.0, 500.0))
    output.show(lines(simulation, second))
    assert len(handle.updates) == 1
    assert "50%" in handle.updates[0].data

    output.show(lines(second))
    assert ParsedHTML(handle.html.data).lines == [render_line(second).plain.rstrip()]
    output.show([])
    assert handle.html.data == ""
    display_html.assert_called_once()
    assert display_html.call_args.kwargs == {"display_id": True}


def test_notebook_close_releases_handle_without_publishing(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Closing forgets the output area without changing it or printing."""
    display_html, handles = notebook_api
    output = NotebookOutput()
    output.show(lines(make_simulation()))
    handle = handles[0]
    initial_html = handle.html.data

    output.close()
    output.close()

    assert output._handle is None
    assert output._last_html is None
    assert handle.html.data == initial_html
    assert handle.updates == []
    display_html.assert_called_once()
    assert capsys.readouterr().out == ""


def test_notebook_requires_a_display_handle(monkeypatch: pytest.MonkeyPatch) -> None:
    """A frontend that returns no handle cannot host the live output area."""
    monkeypatch.setattr(display_module, "_load_notebook_api", Mock(return_value=(FakeHTML, Mock(return_value=None))))
    output = NotebookOutput()

    with pytest.raises(RuntimeError, match="display handle"):
        output.show(lines(make_simulation()))


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
    apply_event(simulation, StatusEvent(SimulationStatus.DONE))
    apply_event(simulation, ConfigEvent(0.0, 2_000.0, 1.0))
    apply_event(simulation, ProgressEvent(1_234.0, 0.25, 3_723_000.0, 65_000.0))
    for severity in ("Notice", "Warning", "Fatal"):
        apply_event(simulation, LogEvent(severity))
    simulations = [simulation, make_simulation(8)]

    output = StringIO()
    console = Console(file=output, width=20, force_jupyter=False, color_system=None)
    console.print(Group(*(render_line(simulation) for simulation in simulations)), soft_wrap=True)
    expected = [render_line(simulation).plain.rstrip() for simulation in simulations]

    parsed = ParsedHTML(NotebookOutput._render_html(lines(*simulations)))

    assert [line.rstrip() for line in output.getvalue().splitlines()] == expected
    assert parsed.lines == expected
    assert len(expected[0]) > console.width
    assert "[#####---------------]  1,234 /  2,000 (25%)" in expected[0]


@pytest.mark.parametrize(
    ("status", "color"),
    [
        (SimulationStatus.DONE, "green"),
        (SimulationStatus.ERROR, "red"),
        (SimulationStatus.TIMEOUT, "red"),
        (SimulationStatus.STALLED, "red"),
        (SimulationStatus.CANCELLED, "yellow"),
    ],
)
def test_notebook_html_is_an_escaped_inline_styled_fragment(
    status: SimulationStatus,
    color: str,
) -> None:
    """Only status spans add color; notebook themes supply the fragment's base colors."""
    simulation = make_simulation(1, "deck<script>&.dck")
    apply_event(simulation, StatusEvent(status))

    html = NotebookOutput._render_html(lines(simulation))
    parsed = ParsedHTML(html)

    assert parsed.lines == [render_line(simulation).plain.rstrip()]
    assert "&lt;script&gt;" in html
    assert "&amp;" in html
    expected_style = Style.parse(color).get_html_style()
    assert any(text.strip() == status.value and expected_style in style for text, style in parsed.spans)
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


def test_notebook_renders_use_fresh_silent_recording_consoles(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Repeated exports contain only current state and never print to either stream."""
    console_factory = Mock(wraps=Console)
    monkeypatch.setattr(display_module, "Console", console_factory)
    simulation = make_simulation()
    apply_event(simulation, StatusEvent(SimulationStatus.RUNNING))

    old_html = NotebookOutput._render_html(lines(simulation))
    apply_event(simulation, StatusEvent(SimulationStatus.DONE))
    new_html = NotebookOutput._render_html(lines(simulation))
    repeated_html = NotebookOutput._render_html(lines(simulation))

    assert "RUNNING" in old_html
    assert "RUNNING" not in new_html
    assert ParsedHTML(new_html).lines == [render_line(simulation).plain.rstrip()]
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


def test_notebook_empty_render_does_not_export_a_blank_line(monkeypatch: pytest.MonkeyPatch) -> None:
    """Empty active output is truly empty and needs no Rich console."""
    console_factory = Mock()
    monkeypatch.setattr(display_module, "Console", console_factory)

    assert NotebookOutput._render_html([]) == ""

    console_factory.assert_not_called()


@pytest.mark.parametrize(
    ("status", "ansi_code"),
    [(SimulationStatus.DONE, 32), (SimulationStatus.ERROR, 31), (SimulationStatus.CANCELLED, 33)],
)
@pytest.mark.parametrize("width", [20, 300])
def test_notebook_finished_lines_use_ansi_stdout_without_wrapping(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    status: SimulationStatus,
    ansi_code: int,
    width: int,
) -> None:
    """One reused stdout console emits status colours, not HTML, at any output width."""
    monkeypatch.delenv("NO_COLOR", raising=False)
    monkeypatch.setenv("COLUMNS", str(width))
    display_html, _ = notebook_api
    output = NotebookOutput()
    console = output._completed_console
    simulation = make_simulation(1, "models/annual-load.dck")
    apply_event(simulation, ConfigEvent(0.0, 2_000.0, 1.0))
    apply_event(simulation, ProgressEvent(2_000.0, 1.0, 3_723_000.0, 0.0))
    apply_event(simulation, StatusEvent(status))

    output.print(render_line(simulation))
    captured = capsys.readouterr()
    streamed = Text.from_ansi(captured.out)

    assert f"\x1b[{ansi_code}m" in captured.out
    assert "\x1b[0m" in captured.out
    assert streamed.plain.rstrip() == render_line(simulation).plain.rstrip()
    assert captured.out.count("\n") == 1
    assert "(100%)" in streamed.plain
    assert captured.err == ""
    assert not console.is_jupyter
    assert console.is_terminal
    assert console.color_system == "standard"
    assert not console.record

    output.print(render_line(simulation))
    assert output._completed_console is console
    assert capsys.readouterr().out.count("\n") == 1
    display_html.assert_not_called()


def test_notebook_finished_colours_respect_no_color(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """NO_COLOR disables ANSI colour escapes without changing the stdout/live split."""
    monkeypatch.setenv("NO_COLOR", "1")
    display_html, _ = notebook_api
    output = NotebookOutput()
    simulation = make_simulation()
    apply_event(simulation, StatusEvent(SimulationStatus.DONE))

    output.print(render_line(simulation))
    captured = capsys.readouterr()

    assert "\x1b" not in captured.out
    assert captured.out.rstrip() == render_line(simulation).plain.rstrip()
    assert captured.out.count("\n") == 1
    assert captured.err == ""
    display_html.assert_not_called()


# -----------------------------------------------------------------
# Output selection
# -----------------------------------------------------------------
def test_auto_output_selects_notebook_for_active_kernel(monkeypatch: pytest.MonkeyPatch) -> None:
    """Auto mode recognizes Jupyter kernels, including VS Code's kernel shell."""
    shell = Mock()
    shell.kernel = object()
    monkeypatch.setattr(builtins, "get_ipython", lambda: shell, raising=False)
    notebook = Mock(spec=NotebookOutput)
    monkeypatch.setattr(display_module, "_NotebookOutput", Mock(return_value=notebook))
    terminal_factory = Mock()
    monkeypatch.setattr(display_module, "_TerminalOutput", terminal_factory)

    assert display_module._auto_output(None) is notebook
    terminal_factory.assert_not_called()


def test_auto_output_selects_terminal_without_kernel(monkeypatch: pytest.MonkeyPatch) -> None:
    """Auto mode keeps Rich in ordinary terminals without loading IPython."""
    monkeypatch.delattr(builtins, "get_ipython", raising=False)
    notebook_loader = Mock()
    monkeypatch.setattr(display_module, "_load_notebook_api", notebook_loader)

    assert isinstance(display_module._auto_output(None), TerminalOutput)
    notebook_loader.assert_not_called()


def test_auto_output_draws_on_a_given_console_even_in_a_kernel(monkeypatch: pytest.MonkeyPatch) -> None:
    """An explicit console wins over notebook detection."""
    shell = Mock()
    shell.kernel = object()
    monkeypatch.setattr(builtins, "get_ipython", lambda: shell, raising=False)
    console = Console(file=StringIO())

    output = display_module._auto_output(console)

    assert isinstance(output, TerminalOutput)
    assert output.console is console


# -----------------------------------------------------------------
# Progress display
# -----------------------------------------------------------------
def make_running(sim_id: int = 1) -> Simulation:
    """Build a simulation a daemon worker has accepted and started."""
    simulation = make_simulation(sim_id)
    _ = simulation.apply(SimulationReply(SimulationState.RUNNING))
    return simulation


def plain(*simulations: Simulation) -> list[str]:
    """Return the text of the lines drawn for simulations."""
    return [line.plain for line in lines(*simulations)]


@pytest.fixture
def output(monkeypatch: pytest.MonkeyPatch) -> Mock:
    """Make every new display draw on a mock output."""
    output = Mock(spec=["show", "print", "close"])
    monkeypatch.setattr(display_module, "_auto_output", Mock(return_value=output))
    return output


def shown(output: Mock) -> list[str]:
    """Return the text of the live lines last shown."""
    ((drawn,), _) = output.show.call_args
    return [line.plain for line in drawn]


def test_progress_display_draws_accepted_runs_never_queued_ones(output: Mock) -> None:
    """Runs a worker took are drawn in the order seen; queued ones never are."""
    queued, second, first = make_simulation(1), make_running(2), make_running(3)
    display = ProgressDisplay()

    display.update([queued, second])
    display.update([first])

    assert shown(output) == plain(second, first)
    output.print.assert_not_called()


def test_progress_display_redraws_changed_rows(output: Mock) -> None:
    """A row that changes again is redrawn in place, keeping its order."""
    first, second = make_running(1), make_running(2)
    display = ProgressDisplay()
    display.update([first, second])

    apply_event(first, ProgressEvent(100.0, 0.5, 500.0, 500.0))
    display.update([first])

    assert shown(output) == plain(first, second)
    assert "(50%)" in shown(output)[0]


def test_progress_display_prints_each_finished_run_once_then_drops_it(output: Mock) -> None:
    """A finished run is printed above the live rows and leaves them, even one never seen running."""
    first, second, third = make_running(1), make_running(2), make_simulation(3)
    display = ProgressDisplay()
    display.update([first, second])
    output.reset_mock()
    finish(second)
    finish(third)

    display.update([second, third])

    assert [printed.plain for ((printed,), _) in output.print.call_args_list] == plain(second, third)
    assert shown(output) == plain(first)
    assert list(display._rows) == [1]


def test_progress_display_close_clears_rows_and_releases_output(output: Mock) -> None:
    """Close prints nothing more, forgets the rows, and releases the output, leaving runs as they were."""
    running = make_running()
    display = ProgressDisplay()
    display.update([running])
    output.reset_mock()
    before = (running.info, running.logs)

    display.close()

    assert output.method_calls == [call.close()]
    assert display._rows == {}
    assert (running.info, running.logs) == before


def test_progress_display_uses_the_given_console(monkeypatch: pytest.MonkeyPatch) -> None:
    """A console passed in receives the live region and final lines."""
    monkeypatch.delattr(builtins, "get_ipython", raising=False)
    buffer = StringIO()
    simulation = make_running()
    display = ProgressDisplay(Console(file=buffer, width=200, color_system=None))

    display.update([simulation])
    finish(simulation)
    display.update([simulation])
    display.close()

    assert render_line(simulation).plain.rstrip() in buffer.getvalue()
