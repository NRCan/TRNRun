"""Tests for ``trnrun.display``: the built-in Rich progress display."""

from collections.abc import Iterator
from io import StringIO
from pathlib import Path

import pytest
from rich.console import Console

from trnrun.core.records import ConfigEvent, ProgressEvent, SimulationInfo, SimulationState, SimulationStatus
from trnrun.core.settings import SimulationSettings
from trnrun.display import (
    PATH_WIDTH,
    ProgressDisplay,
    _format_duration,
    _NotebookOutput,
    _render_line,
    _TerminalOutput,
    _truncate_left,
)
from trnrun.simulation import Simulation

DECK = Path(r"C:\decks\model.dck")


def _simulation(
    run_id: int,
    state: SimulationState,
    status: SimulationStatus | None = None,
    *,
    percent: float | None = None,
) -> Simulation:
    """Return a handle in ``state``, with ``status`` and ``percent`` of 10 simulated hours if given."""
    simulation = Simulation(run_id, DECK, SimulationSettings())
    progress = None
    config = None
    if percent is not None:
        progress = ProgressEvent(time=10 * percent, percent=percent, elapsed_ms=65_000.0, eta_ms=5_000.0)
        config = ConfigEvent(start=0.0, stop=10.0, step=1.0)
    simulation._apply(
        SimulationInfo(
            run_id,
            state,
            deck_file=DECK,
            status=status,
            progress=progress,
            config=config,
            notices=1,
            warnings=2,
            fatals=3,
        ),
        [],
    )
    return simulation


# -----------------------------------------------------------------
# Line rendering
# -----------------------------------------------------------------
@pytest.mark.parametrize(
    ("ms", "text"),
    [
        (None, "--:--:--"),
        (0.0, "00:00:00"),
        (999.9, "00:00:00"),
        (61_000.0, "00:01:01"),
        (3_661_000.0, "01:01:01"),
        (360_000_000.0, "100:00:00"),
        (-5_000.0, "00:00:00"),
    ],
)
def test_format_duration(ms: float | None, text: str) -> None:
    """Format milliseconds as HH:MM:SS, clamping negative ETAs."""
    assert _format_duration(ms) == text


@pytest.mark.parametrize(
    ("text", "width", "expected"),
    [
        ("abc", 5, "abc  "),
        ("abcde", 5, "abcde"),
        ("abcdefgh", 5, "…efgh"),
        ("日本語ab", 5, "…語ab"),
    ],
)
def test_truncate_left(text: str, width: int, expected: str) -> None:
    """Pad short text and keep the end of long text, marking the cut."""
    assert _truncate_left(text, width) == expected


def test_truncate_left_keeps_the_width_with_wide_characters() -> None:
    """Fill exactly ``width`` cells, even when a wide character is cut."""
    console = Console(width=200)

    assert console.measure(_truncate_left("日本語の長いパス", 6)).maximum == 6


def test_render_line_without_progress() -> None:
    """Render placeholders for a run TRNRun has not reported on."""
    line = _render_line(_simulation(1, SimulationState.RUNNING))

    assert line.plain.startswith(f"[1] {_truncate_left(str(DECK), PATH_WIDTH)} | Status: ")
    assert "Logs: N:1 W:2 F:3" in line.plain
    assert "Elapsed: --:--:--" in line.plain
    assert "ETA: --:--:--" in line.plain
    assert "[--------------------] - / -" in line.plain


def test_render_line_with_progress() -> None:
    """Render the bar, simulation time and completion of a running run."""
    line = _render_line(_simulation(2, SimulationState.RUNNING, SimulationStatus.RUNNING, percent=0.5))

    assert "Status: RUNNING " in line.plain
    assert "Elapsed: 00:01:05" in line.plain
    assert "ETA: 00:00:05" in line.plain
    assert "[##########----------]      5 /     10 (50%)" in line.plain
    assert not line.spans  # Unfinished statuses stay plain.


@pytest.mark.parametrize(
    ("status", "style"),
    [
        (SimulationStatus.DONE, "green"),
        (SimulationStatus.CANCELLED, "yellow"),
        (SimulationStatus.ERROR, "red"),
        (SimulationStatus.TIMEOUT, "red"),
        (SimulationStatus.STALLED, "red"),
    ],
)
def test_render_line_colours_final_statuses(status: SimulationStatus, style: str) -> None:
    """Colour only the status word of a final status."""
    line = _render_line(_simulation(1, SimulationState.FINISHED, status))

    assert [line.plain[span.start : span.end].strip() for span in line.spans] == [status.value]
    assert [span.style for span in line.spans] == [style]


def test_render_line_clamps_the_bar() -> None:
    """Keep the bar within its width for out-of-range completion."""
    line = _render_line(_simulation(1, SimulationState.RUNNING, percent=1.5))

    assert "[####################]" in line.plain


def test_render_line_is_cp1252_safe() -> None:
    """Use only characters a redirected Windows console can encode."""
    line = _render_line(_simulation(1, SimulationState.FINISHED, SimulationStatus.DONE, percent=1.0))

    _ = line.plain.encode("cp1252")


# -----------------------------------------------------------------
# Progress display in a terminal
# -----------------------------------------------------------------
@pytest.fixture
def output() -> StringIO:
    """Return the buffer a test console writes to."""
    return StringIO()


@pytest.fixture
def display(output: StringIO) -> Iterator[ProgressDisplay]:
    """Return a display on a wide, non-interactive console."""
    display = ProgressDisplay(Console(file=output, width=200))
    yield display
    display.close()


def test_terminal_console_gets_a_live_region(display: ProgressDisplay) -> None:
    """Draw outside notebooks with a Rich live region."""
    assert isinstance(display._output, _TerminalOutput)


def test_finished_runs_are_printed_once(display: ProgressDisplay, output: StringIO) -> None:
    """Print each finished run once, as a final line that stays."""
    simulation = _simulation(1, SimulationState.RUNNING, SimulationStatus.RUNNING, percent=0.5)
    display.update([simulation])
    simulation._apply(_simulation(1, SimulationState.FINISHED, SimulationStatus.DONE).info, [])

    display.update([simulation])
    display.update([])
    display.close()

    lines = output.getvalue().splitlines()
    assert len(lines) == 1
    assert lines[0].startswith("[1] ")
    assert "Status: DONE" in lines[0]


def test_live_lines_are_the_running_runs_in_start_order(display: ProgressDisplay) -> None:
    """Draw running runs in the order seen, never queued ones, and drop finished ones."""
    queued = _simulation(1, SimulationState.QUEUED)
    second = _simulation(2, SimulationState.RUNNING)
    third = _simulation(3, SimulationState.RUNNING)

    display.update([queued, third])
    display.update([second, third])

    assert list(display._rows) == [3, 2]

    third._apply(SimulationInfo(3, SimulationState.FINISHED, deck_file=DECK), [])
    display.update([third])

    assert list(display._rows) == [2]


def test_live_region_stops_when_empty(display: ProgressDisplay) -> None:
    """Start the live region on demand and stop it once nothing runs."""
    simulation = _simulation(1, SimulationState.RUNNING)
    terminal = display._output
    assert isinstance(terminal, _TerminalOutput)

    display.update([simulation])
    assert terminal._live is not None

    simulation._apply(SimulationInfo(1, SimulationState.FINISHED, deck_file=DECK), [])
    display.update([simulation])
    assert terminal._live is None


def test_close_clears_the_live_lines(display: ProgressDisplay) -> None:
    """Forget the running runs and stop the live region; closing again is safe."""
    display.update([_simulation(1, SimulationState.RUNNING)])

    display.close()
    display.close()

    assert display._rows == {}
    terminal = display._output
    assert isinstance(terminal, _TerminalOutput)
    assert terminal._live is None


# -----------------------------------------------------------------
# Progress display in a notebook
# -----------------------------------------------------------------
class _FakeHandle:
    """Records what a notebook ``DisplayHandle`` would publish."""

    published: list[tuple[str, str]] = []  # noqa: RUF012 - shared by every handle of a test

    def display(self, html: object) -> None:
        """Record the first frame."""
        self.published.append(("display", html.data))  # ty: ignore[unresolved-attribute]  # pyright: ignore[reportAttributeAccessIssue]

    def update(self, html: object) -> None:
        """Record a later frame."""
        self.published.append(("update", html.data))  # ty: ignore[unresolved-attribute]  # pyright: ignore[reportAttributeAccessIssue]


@pytest.fixture
def published(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, str]]:
    """Replace IPython's display handle with a recorder, and return what it records."""
    ipython_display = pytest.importorskip("IPython.display")
    monkeypatch.setattr(ipython_display, "DisplayHandle", _FakeHandle)
    monkeypatch.setattr(_FakeHandle, "published", [])
    return _FakeHandle.published


@pytest.fixture
def notebook(published: list[tuple[str, str]]) -> ProgressDisplay:
    """Return a display on a Jupyter console."""
    _ = published
    return ProgressDisplay(Console(force_jupyter=True))


def test_jupyter_console_gets_an_html_output_area(notebook: ProgressDisplay) -> None:
    """Draw in notebooks with an HTML output area instead of a Rich live region."""
    assert isinstance(notebook._output, _NotebookOutput)


def test_notebook_publishes_changed_frames_only(
    notebook: ProgressDisplay,
    published: list[tuple[str, str]],
) -> None:
    """Publish the area on first use, update it in place, and skip unchanged frames."""
    simulation = _simulation(1, SimulationState.RUNNING, percent=0.25)

    notebook.update([])
    assert published == []

    notebook.update([simulation])
    notebook.update([simulation])
    simulation._apply(_simulation(1, SimulationState.RUNNING, percent=0.5).info, [])
    notebook.update([simulation])

    assert [kind for kind, _ in published] == ["display", "update"]
    assert "(25%)" in published[0][1]
    assert "(50%)" in published[1][1]
    assert published[0][1].startswith("<pre ")


def test_notebook_prints_finished_runs_to_stdout(
    notebook: ProgressDisplay,
    capsys: pytest.CaptureFixture[str],
) -> None:
    """Print each finished run once to stdout, with ANSI status colours."""
    notebook.update([_simulation(1, SimulationState.FINISHED, SimulationStatus.DONE)])

    out = capsys.readouterr().out
    assert "Status: " in out
    assert "\x1b[32mDONE" in out


def test_notebook_close_starts_a_new_area_next_time(
    notebook: ProgressDisplay,
    published: list[tuple[str, str]],
) -> None:
    """Release the output area, so the next frame publishes a new one."""
    simulation = _simulation(1, SimulationState.RUNNING)
    notebook.update([simulation])

    notebook.close()
    notebook.update([simulation])

    assert [kind for kind, _ in published] == ["display", "display"]
