# ruff: noqa: S101, SLF001

from __future__ import annotations

import builtins
import logging
from collections.abc import Callable, Iterator
from dataclasses import dataclass, replace
from html.parser import HTMLParser
from io import StringIO
from threading import Event
from typing import override
from unittest.mock import Mock, call

import pytest
from rich.console import Console, Group
from rich.live import Live
from rich.style import Style
from rich.text import Text

import trnrun.display as display_module
from trnrun.config import SimulationConfig
from trnrun.display import NotebookRenderer, ProgressDisplay, TerminalRenderer
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SimulationState,
    SimulationStatus,
    SimulationUpdate,
    StatusEvent,
)
from trnrun.simulation import Simulation, SimulationSnapshot

TEST_TIMEOUT = 10.0
# Background redraws never happen on their own; tests call `_tick` directly.
NEVER = 3600.0


def make_simulation(sim_id: int = 1, deck_path: str = "deck.dck") -> Simulation:
    """Build an unvalidated simulation for rendering tests."""
    return Simulation(deck_path, SimulationConfig(), sim_id)


def apply_event(simulation: Simulation, event: StatusEvent | ConfigEvent | ProgressEvent | LogEvent) -> None:
    """Fold one runner event into a running simulation, as a daemon poll would."""
    current = SimulationUpdate(
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
        _ = simulation.apply_update(replace(current, **{counter: getattr(current, counter) + 1}), [event])
    elif isinstance(event, StatusEvent):
        _ = simulation.apply_update(replace(current, status=event))
    elif isinstance(event, ConfigEvent):
        _ = simulation.apply_update(replace(current, config=event))
    else:
        _ = simulation.apply_update(replace(current, progress=event))


def finish(simulation: Simulation, status: SimulationStatus = SimulationStatus.DONE) -> None:
    """Finish a simulation as a collected daemon reply would."""
    _ = simulation.apply_update(
        SimulationUpdate(
            SimulationState.FINISHED,
            exit_code=0,
            succeeded=status is SimulationStatus.DONE,
            status=StatusEvent(status),
        ),
    )


def completed_snapshot() -> SimulationSnapshot:
    """Return the snapshot of a fully reported, completed run."""
    simulation = make_simulation(sim_id=7, deck_path="models/annual-load.dck")
    apply_event(simulation, StatusEvent(SimulationStatus.DONE))
    apply_event(simulation, ConfigEvent(0.0, 2_000.0, 1.0))
    apply_event(simulation, ProgressEvent(1_234.0, 0.25, 3_723_000.0, 65_000.0))
    for severity in ("Notice", "Warning", "Fatal"):
        apply_event(simulation, LogEvent(severity))
    return simulation.snapshot()


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
    line = display_module._render_line(make_simulation(sim_id=3).snapshot())

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
    snapshot = completed_snapshot()

    line = display_module._render_line(snapshot)

    assert str(snapshot.deck_path) in line.plain
    assert "Status: DONE" in line.plain
    assert "Logs: N:1 W:1 F:1" in line.plain
    assert "Elapsed: 01:02:03 │ ETA: 00:01:05" in line.plain
    assert "[#####---------------]  1,234 /  2,000 (25%)" in line.plain
    assert any(span.style == "green" and line.plain[span.start : span.end].strip() == "DONE" for span in line.spans)


# -----------------------------------------------------------------
# Terminal renderer
# -----------------------------------------------------------------
@pytest.fixture
def terminal(monkeypatch: pytest.MonkeyPatch) -> tuple[TerminalRenderer, Mock, Mock]:
    """Build a terminal renderer whose console and live regions are mocks."""
    console = Mock(spec=Console)
    live_factory = Mock(side_effect=lambda *_args, **_kwargs: Mock(spec=Live))
    monkeypatch.setattr(display_module, "Live", live_factory)
    return TerminalRenderer(console), console, live_factory


def test_terminal_show_starts_one_manually_refreshed_live_region(
    terminal: tuple[TerminalRenderer, Mock, Mock],
) -> None:
    """The first rows start a transient region; later rows update it in place."""
    renderer, console, live_factory = terminal
    first, second = make_simulation(1).snapshot(), make_simulation(2).snapshot()

    renderer.show([first])
    renderer.show([first, second])

    live_factory.assert_called_once()
    assert live_factory.call_args.kwargs == {"console": console, "auto_refresh": False, "transient": True}
    live = renderer._live
    assert isinstance(live, Mock)
    live.start.assert_called_once_with(refresh=True)
    (group,), kwargs = live.update.call_args
    assert kwargs == {"refresh": True}
    assert isinstance(group, Group)
    assert [line.plain.split(" ", maxsplit=1)[0] for line in group.renderables if isinstance(line, Text)] == [
        "[1]",
        "[2]",
    ]


def test_terminal_show_without_rows_stops_the_region(terminal: tuple[TerminalRenderer, Mock, Mock]) -> None:
    """An empty frame erases the region, and later rows start a fresh one."""
    renderer, _, live_factory = terminal
    renderer.show([])
    live_factory.assert_not_called()

    renderer.show([make_simulation().snapshot()])
    live = renderer._live
    assert isinstance(live, Mock)
    renderer.show([])

    live.stop.assert_called_once_with()
    assert renderer._live is None
    renderer.show([make_simulation().snapshot()])
    assert live_factory.call_count == 2


def test_terminal_finished_prints_the_final_line(terminal: tuple[TerminalRenderer, Mock, Mock]) -> None:
    """Final lines go through the console, above any live region."""
    renderer, console, _ = terminal
    snapshot = completed_snapshot()

    renderer.finished(snapshot)

    (printed,) = console.print.call_args.args
    assert printed.plain == display_module._render_line(snapshot).plain


def test_terminal_close_is_idempotent(terminal: tuple[TerminalRenderer, Mock, Mock]) -> None:
    """Closing stops the region once and prints nothing."""
    renderer, console, _ = terminal
    renderer.show([make_simulation().snapshot()])
    live = renderer._live
    assert isinstance(live, Mock)

    renderer.close()
    renderer.close()

    live.stop.assert_called_once_with()
    console.print.assert_not_called()


# -----------------------------------------------------------------
# Notebook renderer
# -----------------------------------------------------------------
def test_notebook_show_publishes_once_then_replaces_only_changed_frames(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
) -> None:
    """One output area is reused; identical frames are not republished; empty frames clear it."""
    display_html, handles = notebook_api
    renderer = NotebookRenderer()
    simulation = make_simulation(1)
    second = make_simulation(2)

    renderer.show([])
    display_html.assert_not_called()

    renderer.show([simulation.snapshot(), second.snapshot()])
    (handle,) = handles
    renderer.show([simulation.snapshot(), second.snapshot()])
    assert handle.updates == []

    apply_event(simulation, ProgressEvent(100.0, 0.5, 500.0, 500.0))
    renderer.show([simulation.snapshot(), second.snapshot()])
    assert len(handle.updates) == 1
    assert "50%" in handle.updates[0].data

    renderer.show([second.snapshot()])
    assert ParsedHTML(handle.html.data).lines == [display_module._render_line(second.snapshot()).plain.rstrip()]
    renderer.show([])
    assert handle.html.data == ""
    display_html.assert_called_once()
    assert display_html.call_args.kwargs == {"display_id": True}


def test_notebook_close_releases_handle_without_publishing(
    notebook_api: tuple[Mock, list[FakeDisplayHandle]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Closing forgets the output area without changing it or printing."""
    display_html, handles = notebook_api
    renderer = NotebookRenderer()
    renderer.show([make_simulation().snapshot()])
    handle = handles[0]
    initial_html = handle.html.data

    renderer.close()
    renderer.close()

    assert renderer._handle is None
    assert renderer._last_html is None
    assert handle.html.data == initial_html
    assert handle.updates == []
    display_html.assert_called_once()
    assert capsys.readouterr().out == ""


def test_notebook_requires_a_display_handle(monkeypatch: pytest.MonkeyPatch) -> None:
    """A frontend that returns no handle cannot host the live output area."""
    monkeypatch.setattr(display_module, "_load_notebook_api", Mock(return_value=(FakeHTML, Mock(return_value=None))))
    renderer = NotebookRenderer()

    with pytest.raises(RuntimeError, match="display handle"):
        renderer.show([make_simulation().snapshot()])


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
    snapshots = [simulation.snapshot(), make_simulation(8).snapshot()]

    output = StringIO()
    console = Console(file=output, width=20, force_jupyter=False, color_system=None)
    console.print(Group(*(display_module._render_line(snapshot) for snapshot in snapshots)), soft_wrap=True)
    expected = [display_module._render_line(snapshot).plain.rstrip() for snapshot in snapshots]

    parsed = ParsedHTML(NotebookRenderer._render_html(snapshots))

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
    snapshot = simulation.snapshot()

    html = NotebookRenderer._render_html([snapshot])
    parsed = ParsedHTML(html)

    assert parsed.lines == [display_module._render_line(snapshot).plain.rstrip()]
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

    old_html = NotebookRenderer._render_html([simulation.snapshot()])
    apply_event(simulation, StatusEvent(SimulationStatus.DONE))
    new_html = NotebookRenderer._render_html([simulation.snapshot()])
    repeated_html = NotebookRenderer._render_html([simulation.snapshot()])

    assert "RUNNING" in old_html
    assert "RUNNING" not in new_html
    assert ParsedHTML(new_html).lines == [display_module._render_line(simulation.snapshot()).plain.rstrip()]
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

    assert NotebookRenderer._render_html([]) == ""

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
    renderer = NotebookRenderer()
    console = renderer._completed_console
    simulation = make_simulation(1, "models/annual-load.dck")
    apply_event(simulation, ConfigEvent(0.0, 2_000.0, 1.0))
    apply_event(simulation, ProgressEvent(2_000.0, 1.0, 3_723_000.0, 0.0))
    apply_event(simulation, StatusEvent(status))
    snapshot = simulation.snapshot()

    renderer.finished(snapshot)
    captured = capsys.readouterr()
    streamed = Text.from_ansi(captured.out)

    assert f"\x1b[{ansi_code}m" in captured.out
    assert "\x1b[0m" in captured.out
    assert streamed.plain.rstrip() == display_module._render_line(snapshot).plain.rstrip()
    assert captured.out.count("\n") == 1
    assert "(100%)" in streamed.plain
    assert captured.err == ""
    assert not console.is_jupyter
    assert console.is_terminal
    assert console.color_system == "standard"
    assert not console.record

    renderer.finished(snapshot)
    assert renderer._completed_console is console
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
    renderer = NotebookRenderer()
    simulation = make_simulation()
    apply_event(simulation, StatusEvent(SimulationStatus.DONE))
    snapshot = simulation.snapshot()

    renderer.finished(snapshot)
    captured = capsys.readouterr()

    assert "\x1b" not in captured.out
    assert captured.out.rstrip() == display_module._render_line(snapshot).plain.rstrip()
    assert captured.out.count("\n") == 1
    assert captured.err == ""
    display_html.assert_not_called()


# -----------------------------------------------------------------
# Renderer selection
# -----------------------------------------------------------------
def test_auto_renderer_selects_notebook_for_active_kernel(monkeypatch: pytest.MonkeyPatch) -> None:
    """Auto mode recognizes Jupyter kernels, including VS Code's kernel shell."""
    shell = Mock()
    shell.kernel = object()
    monkeypatch.setattr(builtins, "get_ipython", lambda: shell, raising=False)
    notebook = Mock(spec=NotebookRenderer)
    monkeypatch.setattr(display_module, "NotebookRenderer", Mock(return_value=notebook))
    terminal_factory = Mock()
    monkeypatch.setattr(display_module, "TerminalRenderer", terminal_factory)

    assert display_module._auto_renderer() is notebook
    terminal_factory.assert_not_called()


def test_auto_renderer_selects_terminal_without_kernel(monkeypatch: pytest.MonkeyPatch) -> None:
    """Auto mode keeps Rich in ordinary terminals without loading IPython."""
    monkeypatch.delattr(builtins, "get_ipython", raising=False)
    terminal = Mock(spec=TerminalRenderer)
    monkeypatch.setattr(display_module, "TerminalRenderer", Mock(return_value=terminal))
    notebook_loader = Mock()
    monkeypatch.setattr(display_module, "_load_notebook_api", notebook_loader)

    assert display_module._auto_renderer() is terminal
    notebook_loader.assert_not_called()


# -----------------------------------------------------------------
# Progress display
# -----------------------------------------------------------------
class FakeManager:
    """Record tracker attachment, as ``SimulationManager`` exposes it."""

    def __init__(self, unfinished: list[Simulation] | None = None, attach_error: Exception | None = None) -> None:
        self.unfinished: list[Simulation] = unfinished or []
        self.attach_error: Exception | None = attach_error
        self.trackers: list[ProgressDisplay] = []
        self.detached: list[ProgressDisplay] = []

    def _attach(self, tracker: ProgressDisplay) -> None:
        if self.attach_error is not None:
            raise self.attach_error
        self.trackers.append(tracker)
        for simulation in self.unfinished:
            tracker.track(simulation)

    def _detach(self, tracker: ProgressDisplay) -> None:
        self.detached.append(tracker)


@pytest.fixture
def renderer() -> Mock:
    """Return a renderer mock exposing the renderer protocol."""
    return Mock(spec=["show", "finished", "close"])


@pytest.fixture
def make_display(renderer: Mock) -> Iterator[Callable[..., ProgressDisplay]]:
    """Build displays over fake managers, closing each at teardown."""
    displays: list[ProgressDisplay] = []

    def create(manager: FakeManager | None = None, refresh_interval: float = NEVER) -> ProgressDisplay:
        display = ProgressDisplay(
            manager or FakeManager(),  # pyright: ignore[reportArgumentType]
            refresh_interval=refresh_interval,
            renderer=renderer,
        )
        displays.append(display)
        return display

    yield create

    for display in displays:
        display.close()
        assert not display._thread.is_alive()


@pytest.mark.parametrize("refresh_interval", [0.0, -0.01, float("nan")])
def test_progress_display_rejects_nonpositive_refresh_intervals(refresh_interval: float) -> None:
    """Redraws need a positive interval, checked before attaching."""
    manager = FakeManager()
    with pytest.raises(ValueError, match="refresh_interval must be positive"):
        ProgressDisplay(manager, refresh_interval=refresh_interval, renderer=Mock())  # pyright: ignore[reportArgumentType]
    assert manager.trackers == []


def test_progress_display_attaches_and_redraws_in_the_background(
    make_display: Callable[..., ProgressDisplay],
    renderer: Mock,
) -> None:
    """Construction follows the manager's unfinished runs and starts a daemon redraw thread."""
    simulation = make_simulation()
    manager = FakeManager([simulation])
    drawn = Event()
    renderer.show.side_effect = lambda _active: drawn.set()

    display = make_display(manager, refresh_interval=0.01)

    assert manager.trackers == [display]
    assert display._thread.daemon
    assert display._thread.name == "trnrun-progress"
    assert drawn.wait(TEST_TIMEOUT)
    assert renderer.show.call_args.args == ([simulation.snapshot()],)


def test_progress_display_prints_each_finished_run_once_then_drops_it(
    make_display: Callable[..., ProgressDisplay],
    renderer: Mock,
) -> None:
    """Finished runs are printed once and leave the live rows; unfinished ones keep their order."""
    display = make_display()
    first, second, third = make_simulation(1), make_simulation(2), make_simulation(3)
    for simulation in (first, second, third):
        display.track(simulation)
    finish(second)

    display._tick()
    display._tick()

    renderer.finished.assert_called_once_with(second.snapshot())
    assert renderer.show.call_args_list == [call([first.snapshot(), third.snapshot()])] * 2
    assert list(display._rows) == [1, 3]


def test_progress_display_never_misses_a_run_finished_before_its_first_redraw(
    make_display: Callable[..., ProgressDisplay],
    renderer: Mock,
) -> None:
    """A run tracked already finished is printed, never shown as live."""
    display = make_display()
    simulation = make_simulation()
    finish(simulation, SimulationStatus.ERROR)
    display.track(simulation)

    display._tick()

    renderer.finished.assert_called_once_with(simulation.snapshot())
    renderer.show.assert_called_once_with([])


def test_progress_display_logs_renderer_failures_without_repeating_lines(
    make_display: Callable[..., ProgressDisplay],
    renderer: Mock,
    caplog: pytest.LogCaptureFixture,
) -> None:
    """A failing renderer is logged; its final line is not retried and redraws continue."""
    display = make_display()
    simulation = make_simulation()
    display.track(simulation)
    finish(simulation)
    renderer.finished.side_effect = RuntimeError("render failed")

    with caplog.at_level(logging.ERROR, logger="trnrun.display"):
        display._tick()
    display._tick()

    assert [record.exc_info[1] for record in caplog.records if record.exc_info] == [renderer.finished.side_effect]
    renderer.finished.assert_called_once()
    renderer.show.assert_called_once_with([])


def test_progress_display_close_detaches_draws_last_frame_and_releases_renderer(
    make_display: Callable[..., ProgressDisplay],
    renderer: Mock,
) -> None:
    """Close stops the thread, then prints runs finished since the last redraw, exactly once."""
    manager = FakeManager()
    display = make_display(manager)
    running, done = make_simulation(1), make_simulation(2)
    display.track(running)
    display.track(done)
    finish(done)

    display.close()
    display.close()

    assert manager.detached == [display]
    assert not display._thread.is_alive()
    assert renderer.method_calls == [
        call.finished(done.snapshot()),
        call.show([running.snapshot()]),
        call.close(),
    ]


def test_progress_display_context_closes(make_display: Callable[..., ProgressDisplay], renderer: Mock) -> None:
    """Leaving the context closes the display."""
    with make_display() as display:
        assert display._thread.is_alive()
    assert not display._thread.is_alive()
    renderer.close.assert_called_once_with()


def test_progress_display_attach_failure_starts_nothing(renderer: Mock) -> None:
    """A closed manager refuses the display before any thread starts."""
    manager = FakeManager(attach_error=RuntimeError("SimulationManager is closed"))

    with pytest.raises(RuntimeError, match="closed"):
        ProgressDisplay(manager, refresh_interval=NEVER, renderer=renderer)  # pyright: ignore[reportArgumentType]

    renderer.assert_not_called()


def test_progress_display_selects_a_renderer_automatically(monkeypatch: pytest.MonkeyPatch, renderer: Mock) -> None:
    """Without a renderer, the environment decides between terminal and notebook."""
    monkeypatch.setattr(display_module, "_auto_renderer", Mock(return_value=renderer))

    display = ProgressDisplay(FakeManager(), refresh_interval=NEVER)  # pyright: ignore[reportArgumentType]
    display.close()

    renderer.close.assert_called_once_with()
