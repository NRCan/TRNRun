"""Display: render's one line per simulation, in a terminal and in a notebook."""

from datetime import UTC, datetime
from io import StringIO
from pathlib import Path

import pytest
from rich.console import Console

from trnrun import Display, Simulation, SimulationState, SimulationStatus
from trnrun.display import render


class _FakeHandle:
    """Records what a notebook ``DisplayHandle`` would publish."""

    published: list[tuple[str, str]] = []  # noqa: RUF012 - shared by every handle of a test

    def display(self, html: object) -> None:
        """Record the first frame."""
        self.published.append(("display", html.data))  # pyright: ignore[reportAttributeAccessIssue]

    def update(self, html: object) -> None:
        """Record a later frame."""
        self.published.append(("update", html.data))  # pyright: ignore[reportAttributeAccessIssue]


@pytest.fixture
def published(monkeypatch: pytest.MonkeyPatch) -> list[tuple[str, str]]:
    """Replace IPython's display handle with a recorder, and return what it records."""
    ipython_display = pytest.importorskip("IPython.display")
    monkeypatch.setattr(ipython_display, "DisplayHandle", _FakeHandle)
    monkeypatch.setattr(_FakeHandle, "published", [])
    return _FakeHandle.published


def _sim(state: SimulationState, percent: float | None = None, status: SimulationStatus | None = None) -> Simulation:
    """Return simulation 1 of ``a.dck``."""
    return Simulation(sim_id=1, state=state, deck_file=Path("a.dck"), percent=percent, status=status)


def test_render_placeholders_before_anything_is_reported() -> None:
    """A queued simulation shows its state, an empty bar and dashes."""
    line = render(_sim(SimulationState.QUEUED)).plain
    assert line.startswith("[1] a.dck ")
    assert "Status: QUEUED " in line
    assert "Elapsed: --:--:--" in line
    assert "ETA: --:--:--" in line
    assert f"[{'-' * 20}] - / -" in line


def test_render_reported_progress() -> None:
    """Progress, times and log counts show as reported."""
    sim = Simulation(
        sim_id=7,
        state=SimulationState.RUNNING,
        deck_file=Path("a.dck"),
        status=SimulationStatus.RUNNING,
        percent=0.5,
        sim_time=4380,
        stop_time=8760,
        elapsed_ms=3_725_000,
        eta_ms=-5,
        warnings=2,
    )
    line = render(sim).plain
    assert "Status: RUNNING " in line
    assert "Logs: N:0 W:2 F:0 " in line
    assert "Elapsed: 01:02:05" in line
    assert "ETA: 00:00:00" in line  # A negative estimate is clamped.
    assert f"[{'#' * 10}{'-' * 10}]  4,380 /  8,760 (50%)" in line


def test_render_wall_clock_elapsed_without_progress() -> None:
    """Without the runner's elapsed time, the time from start to finish shows."""
    sim = Simulation(
        sim_id=1,
        state=SimulationState.FINISHED,
        deck_file=Path("a.dck"),
        started_at=datetime(2026, 10, 22, 14, 3, 12, tzinfo=UTC),
        finished_at=datetime(2026, 10, 22, 14, 4, 17, tzinfo=UTC),
    )
    assert "Elapsed: 00:01:05" in render(sim).plain


def test_render_name_and_bar_bounds() -> None:
    """The label wins over the deck; a long name keeps its end; the bar never overflows."""
    labelled = Simulation(sim_id=1, state=SimulationState.RUNNING, deck_file=Path("a.dck"), label="mine", percent=1.5)
    assert render(labelled).plain.startswith("[1] mine ")
    assert f"[{'#' * 20}]" in render(labelled).plain
    long = Simulation(sim_id=1, state=SimulationState.RUNNING, deck_file=Path("x" * 40) / "end.dck")
    assert f"[1] …{'x' * 23}\\end.dck |" in render(long).plain


def test_render_colours_final_statuses_only() -> None:
    """DONE is green and ERROR red; a running status stays plain."""
    styles = {
        status: {str(span.style) for span in render(_sim(SimulationState.FINISHED, status=status)).spans}
        for status in (SimulationStatus.DONE, SimulationStatus.ERROR, SimulationStatus.RUNNING)
    }
    assert styles == {
        SimulationStatus.DONE: {"green"},
        SimulationStatus.ERROR: {"red"},
        SimulationStatus.RUNNING: set(),
    }


def test_terminal_prints_finished_runs_once() -> None:
    """Finished runs are printed and stay; the transient live lines are erased on close."""
    out = StringIO()
    display = Display(Console(file=out, force_terminal=True, width=200))
    display.update([_sim(SimulationState.RUNNING, 0.25)], [])
    display.update([], [_sim(SimulationState.FINISHED, 1, SimulationStatus.DONE)])
    display.update([], [])
    display.close()
    display.close()
    assert out.getvalue().count("DONE") == 1


def test_notebook_publishes_changed_frames_only(published: list[tuple[str, str]]) -> None:
    """The area is published on first use, updated in place, and unchanged frames are skipped."""
    display = Display(Console(force_jupyter=True))
    display.update([], [])
    assert published == []
    display.update([_sim(SimulationState.RUNNING, 0.25)], [])
    display.update([_sim(SimulationState.RUNNING, 0.25)], [])
    display.update([_sim(SimulationState.RUNNING, 0.5)], [])
    assert [kind for kind, _ in published] == ["display", "update"]
    assert published[0][1].startswith("<pre ")
    assert "25%" in published[0][1]
    assert "50%" in published[1][1]
    display.close()
    display.update([_sim(SimulationState.RUNNING, 0.5)], [])
    assert published[-1][0] == "display"  # A closed area is never reused.


def test_notebook_prints_finished_runs_to_stdout(
    published: list[tuple[str, str]],
    capsys: pytest.CaptureFixture[str],
) -> None:
    """A finished run goes to stdout, once, not into the area."""
    display = Display(Console(force_jupyter=True))
    display.update([], [_sim(SimulationState.FINISHED, 1, SimulationStatus.DONE)])
    assert "DONE" in capsys.readouterr().out
    assert published == []
