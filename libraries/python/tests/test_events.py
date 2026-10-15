"""Tests for ``trnrun.events``: the typed TRNRun events trnrund saves."""

from dataclasses import FrozenInstanceError

import pytest

from trnrun.events import ConfigEvent, LogEvent, ProgressEvent, SettingEvent, SimulationStatus, StatusEvent


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


def test_status_event_message_defaults_to_empty() -> None:
    """Report no detail as an empty message, not None."""
    assert StatusEvent(SimulationStatus.RUNNING).message == ""


def test_log_event_optional_fields_default_to_none() -> None:
    """Require only the severity and time TRNSYS always attaches."""
    log = LogEvent(log_id=1, run_id=2, severity="Notice", time=0.5)

    assert (log.unit_id, log.type_id, log.message_code, log.message, log.information) == (None,) * 5


@pytest.mark.parametrize(
    ("event", "name"),
    [
        (StatusEvent(SimulationStatus.DONE), "status"),
        (ProgressEvent(time=1.0, percent=0.5, elapsed_ms=10.0, eta_ms=10.0), "percent"),
        (ConfigEvent(start=0.0, stop=8_760.0, step=1.0), "stop"),
        (LogEvent(log_id=1, run_id=1, severity="Fatal", time=0.0), "message"),
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


def test_setting_event_holds_every_setting() -> None:
    """Build a setting event from keyword fields, as the row parser does."""
    setting = SettingEvent(
        trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe",
        gui_visibility="hidden",
        wait_for_gui=True,
        wait_for_lst=True,
        wait_for_tmp=False,
        detect_timeout_ms=300_000,
        extra_delay_ms=0,
        watch_log=True,
        watch_tmp=False,
        watch_timeout_ms=0,
        stall_timeout_ms=0,
        poll_ms=100,
        clean_on_success=False,
        kill_on_timeout=False,
        kill_on_stall=False,
        severity="Notice",
        write_events=False,
    )

    assert setting.detect_timeout_ms == 300_000
    assert setting.poll_ms == 100
