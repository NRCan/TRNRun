"""Tests for the run records and reply parsers in ``trnrun.core.records``."""

from dataclasses import FrozenInstanceError
from datetime import UTC, datetime
from pathlib import Path
from typing import cast

import pytest

from tests.helpers import SETTING
from trnrun.core.records import (
    ConfigEvent,
    LogEvent,
    LogSeverity,
    ProgressEvent,
    SimulationInfo,
    SimulationState,
    SimulationStatus,
    parse_run,
)

DECK = Path(r"C:\decks\model.dck")
SUBMITTED_AT = "2026-10-09T14:03:12.345Z"
RUN_FIELDS: tuple[str, ...] = (
    "label",
    "trnrunStatus",
    "trnrunMessage",
    "percent",
    "simTime",
    "elapsedMs",
    "etaMs",
    "succeeded",
    "exitCode",
    "error",
    "startedAt",
    "finishedAt",
    "startTime",
    "stopTime",
    "timeStep",
    "setting",
)  # Null until reported.
LOG_FIELDS: tuple[str, ...] = ("unitId", "typeId", "messageCode", "message", "information")  # Null if none.


def run_object(**fields: object) -> dict[str, object]:
    """Return a run object as trnrund replies with it: run 1, queued, unless ``fields`` say otherwise."""
    run = dict.fromkeys(RUN_FIELDS, cast("object", None))
    run.update(
        runId=1,
        state="QUEUED",
        notices=0,
        warnings=0,
        fatals=0,
        submittedAt=SUBMITTED_AT,
        deckFile=str(DECK),
        trnrunArgs=[],
        logs=[],
    )
    run.update(fields)
    return run


def log_object(**fields: object) -> dict[str, object]:
    """Return a Notice log object as trnrund replies with it, unless ``fields`` say otherwise."""
    log = dict.fromkeys(LOG_FIELDS, cast("object", None))
    log.update(severity="Notice", simTime=0.0)
    log.update(fields)
    return log


# -----------------------------------------------------------------
# Records
# -----------------------------------------------------------------
def test_simulation_state_values_are_the_daemon_names() -> None:
    """Keep the enum values equal to the states trnrund reports."""
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
    assert first.logs == []
    assert first.logs is not second.logs


def test_simulation_info_is_frozen() -> None:
    """Keep snapshots immutable, so handles can share them."""
    with pytest.raises(FrozenInstanceError):
        SimulationInfo(1, SimulationState.QUEUED, DECK).state = SimulationState.RUNNING  # ty: ignore[invalid-assignment]  # pyright: ignore[reportAttributeAccessIssue]


# -----------------------------------------------------------------
# parse_run
# -----------------------------------------------------------------
def test_parse_run_of_a_queued_run() -> None:
    """Turn a run TRNRun has not reported on into None events and an empty outcome."""
    info = parse_run(run_object(label="baseline", trnrunArgs=["--pollMs:10"]))

    assert info == SimulationInfo(
        run_id=1,
        state=SimulationState.QUEUED,
        label="baseline",
        deck_file=DECK,
        trnrun_args=["--pollMs:10"],
        submitted_at=datetime(2026, 10, 9, 14, 3, 12, 345_000, tzinfo=UTC),
    )


def test_parse_run_of_a_finished_run() -> None:
    """Group the flat fields back into the events they came from."""
    info = parse_run(
        run_object(
            state="FINISHED",
            trnrunStatus="DONE",
            trnrunMessage="All good",
            percent=1.0,
            simTime=8_760.0,
            elapsedMs=1_500.0,
            etaMs=0.0,
            startTime=0.0,
            stopTime=8_760.0,
            timeStep=1.0,
            setting=SETTING,
            notices=3,
            warnings=2,
            fatals=1,
            succeeded=True,
            exitCode=0,
            startedAt="2026-10-09T14:03:13.000Z",
            finishedAt="2026-10-09T14:05:00.500Z",
        ),
    )

    assert info.state is SimulationState.FINISHED
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


def test_parse_run_of_a_failed_run() -> None:
    """Keep the daemon error and exit code, and read a null message as None."""
    info = parse_run(
        run_object(state="FINISHED", trnrunStatus="ERROR", succeeded=False, exitCode=1, error="Cannot start TRNRun"),
    )

    assert info.status is SimulationStatus.ERROR
    assert info.status_message is None
    assert info.succeeded is False
    assert info.exit_code == 1
    assert info.error == "Cannot start TRNRun"


def test_parse_run_keeps_unfinished_outcome_none() -> None:
    """Read a null ``succeeded`` as None until the run finishes, so unfinished is not failed."""
    info = parse_run(run_object(state="RUNNING", startedAt="2026-10-09T14:03:13.000Z"))

    assert info.succeeded is None
    assert info.exit_code is None
    assert info.started_at is not None
    assert info.finished_at is None


def test_parse_run_rejects_an_unknown_state() -> None:
    """Fail on a state from a newer trnrund rather than misreport it."""
    with pytest.raises(ValueError, match="PAUSED"):
        _ = parse_run(run_object(state="PAUSED"))


# -----------------------------------------------------------------
# Logs
# -----------------------------------------------------------------
def test_parse_run_reads_its_logs_in_order() -> None:
    """Read each log object of the run into its LogEvent, keeping null fields as None."""
    info = parse_run(
        run_object(
            logs=[
                log_object(
                    severity="Warning",
                    simTime=2_190.5,
                    unitId=12,
                    typeId=56,
                    messageCode=123,
                    message="Example warning",
                    information="Example details",
                ),
                log_object(severity="Fatal", simTime=1.0),
            ],
        ),
    )

    assert info.logs == [
        LogEvent(
            severity=LogSeverity.WARNING,
            time=2_190.5,
            unit_id=12,
            type_id=56,
            message_code=123,
            message="Example warning",
            information="Example details",
        ),
        LogEvent(severity=LogSeverity.FATAL, time=1.0),
    ]
