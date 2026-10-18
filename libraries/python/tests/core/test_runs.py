"""Tests for the run records in ``trnrun.core.records`` and the row parsers in ``trnrun.core.database``."""

import json
import sqlite3
from collections.abc import Iterator
from dataclasses import FrozenInstanceError
from datetime import UTC, datetime
from pathlib import Path

import pytest

from tests.helpers import SETTING, create_database, fetch_row, insert_log, insert_run
from trnrun.core.database import parse_log, parse_run
from trnrun.core.records import (
    Changes,
    ConfigEvent,
    LogEvent,
    LogSeverity,
    ProgressEvent,
    SimulationInfo,
    SimulationState,
    SimulationStatus,
)

DECK = Path(r"C:\decks\model.dck")


@pytest.fixture
def connection(tmp_path: Path) -> Iterator[sqlite3.Connection]:
    """Return a writable connection to an empty trnrund database."""
    connection = create_database(tmp_path / "runs.sqlite3")
    yield connection
    connection.close()


# -----------------------------------------------------------------
# Records
# -----------------------------------------------------------------
def test_simulation_state_values_are_the_daemon_names() -> None:
    """Keep the enum values equal to the states trnrund saves."""
    assert [state.value for state in SimulationState] == ["QUEUED", "RUNNING", "FINISHED"]


@pytest.mark.parametrize(
    ("state", "finished"),
    [(SimulationState.QUEUED, False), (SimulationState.RUNNING, False), (SimulationState.FINISHED, True)],
)
def test_simulation_info_is_finished_only_when_finished(state: SimulationState, finished: bool) -> None:  # noqa: FBT001 - parametrized
    """Report a run finished only once the daemon finished it."""
    assert SimulationInfo(1, state, DECK).is_finished is finished


def test_simulation_info_defaults_describe_a_fresh_run() -> None:
    """Start with no events, no counts, no outcome and independent argument lists."""
    first = SimulationInfo(1, SimulationState.QUEUED, DECK)
    second = SimulationInfo(2, SimulationState.QUEUED, DECK)

    assert (first.status, first.status_message, first.progress, first.config, first.setting) == (None,) * 5
    assert (first.notices, first.warnings, first.fatals) == (0, 0, 0)
    assert (first.succeeded, first.exit_code, first.error) == (None, None, None)
    assert first.trnrun_args is not second.trnrun_args


def test_simulation_info_is_frozen() -> None:
    """Keep snapshots immutable, so handles can share them across threads."""
    with pytest.raises(FrozenInstanceError):
        SimulationInfo(1, SimulationState.QUEUED, DECK).state = SimulationState.RUNNING  # ty: ignore[invalid-assignment]  # pyright: ignore[reportAttributeAccessIssue]


def test_changes_are_truthy_only_when_something_changed() -> None:
    """Let ``if changes:`` skip empty polls."""
    assert not Changes()
    assert Changes(runs=[SimulationInfo(1, SimulationState.QUEUED, DECK)])
    assert Changes(logs=[LogEvent(log_id=1, run_id=1, severity=LogSeverity.NOTICE, time=0.0)])


# -----------------------------------------------------------------
# parse_run
# -----------------------------------------------------------------
def test_parse_run_of_a_queued_run(connection: sqlite3.Connection) -> None:
    """Turn a run TRNRun has not reported on into None events and an empty outcome."""
    run_id = insert_run(connection, label="baseline", trnrun_args=json.dumps(["--pollMs:10"]))

    info = parse_run(fetch_row(connection, "runs", "run_id", run_id))

    assert info == SimulationInfo(
        run_id=run_id,
        state=SimulationState.QUEUED,
        session_id=1,
        label="baseline",
        revision=1,
        deck_file=Path(r"C:\decks\model.dck"),
        trnrun_args=["--pollMs:10"],
        submitted_at=datetime(2026, 10, 9, 14, 3, 12, 345_000, tzinfo=UTC),
    )


def test_parse_run_of_a_finished_run(connection: sqlite3.Connection) -> None:
    """Group the flattened columns back into the events they came from."""
    run_id = insert_run(
        connection,
        session_id=4,
        state="FINISHED",
        trnrun_status="DONE",
        trnrun_message="All good",
        percent=1.0,
        sim_time=8_760.0,
        elapsed_ms=1_500.0,
        eta_ms=0.0,
        start_time=0.0,
        stop_time=8_760.0,
        time_step=1.0,
        setting=json.dumps(SETTING),
        notices=3,
        warnings=2,
        fatals=1,
        succeeded=1,
        exit_code=0,
        started_at="2026-10-09T14:03:13.000Z",
        finished_at="2026-10-09T14:05:00.500Z",
    )

    info = parse_run(fetch_row(connection, "runs", "run_id", run_id))

    assert info.state is SimulationState.FINISHED
    assert info.session_id == 4
    assert info.status is SimulationStatus.DONE
    assert info.status_message == "All good"
    assert info.progress == ProgressEvent(time=8_760.0, percent=1.0, elapsed_ms=1_500.0, eta_ms=0.0)
    assert info.config == ConfigEvent(start=0.0, stop=8_760.0, step=1.0)
    assert info.setting == SETTING
    assert (info.notices, info.warnings, info.fatals) == (3, 2, 1)
    assert info.succeeded is True
    assert info.exit_code == 0
    assert info.error is None
    assert info.started_at == datetime(2026, 10, 9, 14, 3, 13, tzinfo=UTC)
    assert info.finished_at == datetime(2026, 10, 9, 14, 5, 0, 500_000, tzinfo=UTC)
    assert info.is_finished


def test_parse_run_of_a_failed_run(connection: sqlite3.Connection) -> None:
    """Keep the daemon error and exit code, and read a NULL message as None."""
    run_id = insert_run(
        connection,
        state="FINISHED",
        trnrun_status="ERROR",
        succeeded=0,
        exit_code=1,
        error="Cannot start TRNRun",
    )

    info = parse_run(fetch_row(connection, "runs", "run_id", run_id))

    assert info.status is SimulationStatus.ERROR
    assert info.status_message is None
    assert info.succeeded is False
    assert info.exit_code == 1
    assert info.error == "Cannot start TRNRun"


def test_parse_run_keeps_unfinished_outcome_none(connection: sqlite3.Connection) -> None:
    """Read a NULL ``succeeded`` as None until the run finishes, so unfinished is not failed."""
    run_id = insert_run(connection, state="RUNNING", started_at="2026-10-09T14:03:13.000Z")

    info = parse_run(fetch_row(connection, "runs", "run_id", run_id))

    assert info.succeeded is None
    assert info.exit_code is None
    assert info.started_at is not None
    assert info.finished_at is None


def test_parse_run_rejects_an_unknown_state(connection: sqlite3.Connection) -> None:
    """Fail on a state saved by a newer trnrund rather than misreport it."""
    run_id = insert_run(connection, state="PAUSED")

    with pytest.raises(ValueError, match="PAUSED"):
        _ = parse_run(fetch_row(connection, "runs", "run_id", run_id))


# -----------------------------------------------------------------
# parse_log
# -----------------------------------------------------------------
def test_parse_log_with_every_field(connection: sqlite3.Connection) -> None:
    """Read each column into its LogEvent field."""
    log_id = insert_log(
        connection,
        7,
        severity="Warning",
        sim_time=2_190.5,
        unit_id=12,
        type_id=56,
        message_code=123,
        message="Example warning",
        information="Example details",
    )

    log = parse_log(fetch_row(connection, "logs", "log_id", log_id))

    assert log == LogEvent(
        log_id=log_id,
        run_id=7,
        severity=LogSeverity.WARNING,
        time=2_190.5,
        unit_id=12,
        type_id=56,
        message_code=123,
        message="Example warning",
        information="Example details",
    )


def test_parse_log_with_only_required_fields(connection: sqlite3.Connection) -> None:
    """Keep the fields TRNSYS did not attach as None."""
    log_id = insert_log(connection, 3, severity="Fatal", sim_time=1.0)

    assert parse_log(fetch_row(connection, "logs", "log_id", log_id)) == LogEvent(
        log_id=log_id,
        run_id=3,
        severity=LogSeverity.FATAL,
        time=1.0,
    )
