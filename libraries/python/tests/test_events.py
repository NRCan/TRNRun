"""Tests for ``trnrun.events``: the typed TRNRun events trnrund saves."""

from dataclasses import FrozenInstanceError

import pytest

from trnrun.events import ConfigEvent, LogEvent, LogSeverity, ProgressEvent, SimulationStatus


def test_simulation_status_values_are_the_runner_names() -> None:
    """Keep the enum values equal to the STATUS strings TRNRun writes."""
    assert [status.value for status in SimulationStatus] == [
        "PENDING",
        "LAUNCHING",
        "RUNNING",
        "DONE",
        "CANCELLED",
        "ERROR",
        "TIMEOUT",
        "STALLED",
    ]


def test_simulation_status_compares_as_its_string() -> None:
    """Let callers compare a status with the plain string TRNRun writes."""
    assert SimulationStatus.DONE == "DONE"
    assert SimulationStatus("STALLED") is SimulationStatus.STALLED
    assert f"{SimulationStatus.ERROR}" == "ERROR"


def test_unknown_simulation_status_is_rejected() -> None:
    """Fail loudly on a status this package does not know."""
    with pytest.raises(ValueError, match="BOGUS"):
        _ = SimulationStatus("BOGUS")


def test_log_event_optional_fields_default_to_none() -> None:
    """Require only the severity and time TRNSYS always attaches."""
    log = LogEvent(log_id=1, run_id=2, severity=LogSeverity.NOTICE, time=0.5)

    assert (log.unit_id, log.type_id, log.message_code, log.message, log.information) == (None,) * 5


@pytest.mark.parametrize(
    ("event", "name"),
    [
        (ProgressEvent(time=1.0, percent=0.5, elapsed_ms=10.0, eta_ms=10.0), "percent"),
        (ConfigEvent(start=0.0, stop=8_760.0, step=1.0), "stop"),
        (LogEvent(log_id=1, run_id=1, severity=LogSeverity.FATAL, time=0.0), "message"),
    ],
)
def test_events_are_frozen(event: object, name: str) -> None:
    """Keep events immutable, so a shared snapshot cannot change under its readers."""
    with pytest.raises(FrozenInstanceError):
        setattr(event, name, None)


def test_events_compare_and_hash_by_value() -> None:
    """Let equal events deduplicate and compare equal."""
    first = ProgressEvent(time=1.0, percent=0.5, elapsed_ms=10.0, eta_ms=10.0)
    second = ProgressEvent(time=1.0, percent=0.5, elapsed_ms=10.0, eta_ms=10.0)

    assert first == second
    assert len({first, second}) == 1
