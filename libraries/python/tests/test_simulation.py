"""Tests for ``trnrun.simulation``: the handle a manager keeps in sync."""

from dataclasses import fields
from pathlib import Path

from trnrun.core.records import LogEvent, LogSeverity, ProgressEvent, SimulationInfo, SimulationState, SimulationStatus
from trnrun.core.settings import SimulationSettings
from trnrun.simulation import Simulation

DECK = Path(r"C:\decks\model.dck")


def _log(log_id: int, severity: LogSeverity = LogSeverity.NOTICE) -> LogEvent:
    """Return a log entry of run 1."""
    return LogEvent(log_id=log_id, run_id=1, severity=severity, time=float(log_id))


def test_new_handle_is_queued_and_empty() -> None:
    """Start as a queued run with no events, counts, outcome or logs."""
    settings = SimulationSettings(poll_ms=10)
    simulation = Simulation(1, str(DECK), settings)

    assert simulation.run_id == 1
    assert simulation.deck_file == DECK
    assert simulation.settings is settings
    assert simulation.info == SimulationInfo(1, SimulationState.QUEUED, deck_file=DECK)
    assert simulation.state is SimulationState.QUEUED
    assert simulation.status is None
    assert simulation.progress is None
    assert (simulation.notices, simulation.warnings, simulation.fatals) == (0, 0, 0)
    assert simulation.succeeded is None
    assert simulation.error is None
    assert simulation.logs == []
    assert not simulation.is_finished


def test_properties_share_the_names_of_info_fields() -> None:
    """Keep one vocabulary: every shortcut is the ``SimulationInfo`` field of the same name."""
    info_fields = {info_field.name for info_field in fields(SimulationInfo)} | {"is_finished"}
    shortcuts = {name for name, value in vars(Simulation).items() if isinstance(value, property)} - {"info", "logs"}

    assert shortcuts <= info_fields


def test_apply_replaces_info_and_appends_logs() -> None:
    """Replace the whole snapshot, and accumulate every log entry."""
    simulation = Simulation(1, DECK, SimulationSettings())
    running = SimulationInfo(
        1,
        SimulationState.RUNNING,
        DECK,
        status=SimulationStatus.RUNNING,
        progress=ProgressEvent(time=5.0, percent=0.5, elapsed_ms=100.0, eta_ms=100.0),
        notices=1,
        warnings=1,
    )

    simulation._apply(running, [_log(1), _log(2, LogSeverity.WARNING)])
    simulation._apply(None, [_log(3)])

    assert simulation.info is running
    assert simulation.state is SimulationState.RUNNING
    assert simulation.status is SimulationStatus.RUNNING
    assert simulation.progress == running.progress
    assert (simulation.notices, simulation.warnings) == (1, 1)
    assert [log.log_id for log in simulation.logs] == [1, 2, 3]


def test_finished_handle_reports_its_outcome() -> None:
    """Expose the outcome fields of a finished run."""
    simulation = Simulation(1, DECK, SimulationSettings())

    simulation._apply(
        SimulationInfo(
            1,
            SimulationState.FINISHED,
            deck_file=DECK,
            status=SimulationStatus.ERROR,
            status_message="Fake failure",
            fatals=2,
            succeeded=False,
            error="Cannot read TRNRun output",
        ),
        [],
    )

    assert simulation.is_finished
    assert simulation.status is SimulationStatus.ERROR
    assert simulation.info.status_message == "Fake failure"
    assert simulation.fatals == 2
    assert simulation.succeeded is False
    assert simulation.error == "Cannot read TRNRun output"


def test_logs_returns_a_copy() -> None:
    """Keep the history safe from callers changing the returned list."""
    simulation = Simulation(1, DECK, SimulationSettings())
    simulation._apply(None, [_log(1)])

    simulation.logs.clear()

    assert len(simulation.logs) == 1


def test_repr_summarizes_the_run() -> None:
    """Show the ID, deck name, state, status and completion."""
    simulation = Simulation(3, DECK, SimulationSettings())

    assert repr(simulation) == "Simulation(run_id=3, deck='model.dck', state=QUEUED, status=None)"

    simulation._apply(
        SimulationInfo(
            3,
            SimulationState.RUNNING,
            deck_file=DECK,
            status=SimulationStatus.RUNNING,
            progress=ProgressEvent(time=4.2, percent=0.42, elapsed_ms=1.0, eta_ms=1.0),
        ),
        [],
    )

    assert repr(simulation) == "Simulation(run_id=3, deck='model.dck', state=RUNNING, status=RUNNING, 42%)"
