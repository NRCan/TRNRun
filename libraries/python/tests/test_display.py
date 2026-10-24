"""Display in a notebook: one HTML output area replaced in place, finished runs printed to stdout."""

from pathlib import Path

import pytest
from rich.console import Console

from trnrun import Display, Simulation, SimulationState, SimulationStatus


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
