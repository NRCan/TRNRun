"""parse_simulation and Simulation: trnrund's simulation objects as records."""

from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

from trnrun import LogEvent, LogSeverity, Simulation, SimulationState, SimulationStatus, parse_simulation


def _raw(**fields: Any) -> dict[str, Any]:
    """Return a finished simulation object as trnrund sends it, with ``fields`` overridden."""
    sim: dict[str, Any] = {
        "simId": 1,
        "label": "building-a",
        "state": "FINISHED",
        "trnrunStatus": "DONE",
        "trnrunMessage": "",
        "percent": 1.0,
        "simTime": 8760.0,
        "elapsedMs": 5321.0,
        "etaMs": 0.0,
        "notices": 2,
        "warnings": 1,
        "fatals": 0,
        "succeeded": True,
        "exitCode": 0,
        "error": None,
        "submittedAt": "2026-10-22T14:03:12.345Z",
        "startedAt": "2026-10-22T14:03:12.351Z",
        "finishedAt": "2026-10-22T14:03:17.702Z",
        "deckFile": "C:\\models\\building-a.dck",
        "trnrunArgs": ["--guiVisibility:min"],
        "startTime": 0.0,
        "stopTime": 8760.0,
        "timeStep": 1.0,
        "setting": {"guiVisibility": "min"},
        "logs": [
            {
                "severity": "Warning",
                "time": 12.0,
                "unitId": 5,
                "typeId": 56,
                "messageCode": None,
                "message": "careful",
                "information": None,
            },
        ],
    }
    sim.update(fields)
    return sim


def test_parse_every_field() -> None:
    """Every field is converted to its Python type and snake_case name."""
    assert parse_simulation(_raw()) == Simulation(
        sim_id=1,
        state=SimulationState.FINISHED,
        deck_file=Path("C:\\models\\building-a.dck"),
        label="building-a",
        trnrun_args=["--guiVisibility:min"],
        status=SimulationStatus.DONE,
        status_message="",
        sim_time=8760.0,
        percent=1.0,
        elapsed_ms=5321.0,
        eta_ms=0.0,
        start_time=0.0,
        stop_time=8760.0,
        time_step=1.0,
        setting={"guiVisibility": "min"},
        notices=2,
        warnings=1,
        fatals=0,
        logs=[LogEvent(LogSeverity.WARNING, 12.0, unit_id=5, type_id=56, message="careful")],
        succeeded=True,
        exit_code=0,
        error=None,
        submitted_at=datetime(2026, 10, 22, 14, 3, 12, 345000, tzinfo=UTC),
        started_at=datetime(2026, 10, 22, 14, 3, 12, 351000, tzinfo=UTC),
        finished_at=datetime(2026, 10, 22, 14, 3, 17, 702000, tzinfo=UTC),
    )


def test_parse_values_not_reported_yet() -> None:
    """A queued simulation's nulls stay None, and a missing ``logs`` is an empty list."""
    raw = _raw(state="QUEUED", trnrunStatus=None, percent=None, startedAt=None, finishedAt=None, succeeded=None)
    del raw["logs"]
    sim = parse_simulation(raw)
    assert (sim.state, sim.status, sim.percent, sim.started_at, sim.finished_at) == ("QUEUED", None, None, None, None)
    assert sim.logs == []
    assert not sim.is_finished


def test_parse_refuses_unknown_values() -> None:
    """An unknown state, status or severity raises ValueError instead of passing through."""
    for raw in (_raw(state="DONE"), _raw(trnrunStatus="NOPE"), _raw(logs=[{**_raw()["logs"][0], "severity": "x"}])):
        with pytest.raises(ValueError, match="is not a valid"):
            _ = parse_simulation(raw)


def test_repr_summarizes() -> None:
    """The repr shows the deck's name, and the percent only once reported."""
    assert repr(parse_simulation(_raw())) == (
        "Simulation(sim_id=1, deck='building-a.dck', state=FINISHED, status=DONE, 100%)"
    )
    assert repr(Simulation(sim_id=2, state=SimulationState.QUEUED, deck_file=Path("a.dck"))) == (
        "Simulation(sim_id=2, deck='a.dck', state=QUEUED, status=None)"
    )
