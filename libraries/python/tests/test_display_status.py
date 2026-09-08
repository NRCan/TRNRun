"""Display statuses come directly from runner events."""

# ruff: noqa: S101
# pyright: reportPrivateUsage=false

from __future__ import annotations

import pytest

from trnrun.config import SimulationConfig
from trnrun.display import Display
from trnrun.events import QueueEvent, StatusEvent
from trnrun.simulation import Simulation


@pytest.mark.parametrize("status", [None, "PENDING", "RUNNING", "DONE", "custom"])
@pytest.mark.parametrize("finished", [False, True])
def test_status_column_preserves_reported_status(
    status: str | None,
    *,
    finished: bool,
) -> None:
    """Acceptance and completion never invent or replace a runner status."""
    simulation = Simulation("test.dck", SimulationConfig(), sim_id=1)
    simulation.mark_accepted()
    if status is not None:
        simulation.apply_event(StatusEvent(status, "2026-09-07T12:00:00Z"))
    if finished:
        simulation.mark_completed(QueueEvent("COMPLETED", "1", "2026-09-07T12:00:01Z", 0))

    line = Display()._render_line(simulation).plain  # noqa: SLF001 - test rendering without starting Live
    label = line.split("Status: ", 1)[1].split(" │ ", 1)[0].rstrip()

    assert label == (status if status is not None else "")
