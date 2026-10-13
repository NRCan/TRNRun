# ruff: noqa: D103, S101

from dataclasses import FrozenInstanceError

import pytest

from tests.test_database import SETTING_PAYLOAD
from trnrun import SimulationState as ExportedSimulationState
from trnrun import SimulationStatus as ExportedSimulationStatus
from trnrun.events import SettingEvent, SimulationState, SimulationStatus, StatusEvent, parse_setting


def test_simulation_status_has_exact_native_values_and_is_exported() -> None:
    expected = ["PENDING", "LAUNCHING", "RUNNING", "DONE", "CANCELLED", "ERROR", "TIMEOUT", "STALLED"]

    assert [status.name for status in SimulationStatus] == expected
    assert [status.value for status in SimulationStatus] == expected
    assert ExportedSimulationStatus is SimulationStatus


def test_simulation_state_has_exact_daemon_values_and_is_exported() -> None:
    assert [state.value for state in SimulationState] == ["QUEUED", "ACCEPTED", "RUNNING", "FINISHED"]
    assert ExportedSimulationState is SimulationState


def test_parse_setting_converts_field_names() -> None:
    setting = parse_setting(SETTING_PAYLOAD)

    assert setting.trnexe_path == SETTING_PAYLOAD["trnexePath"]
    assert setting.detect_timeout_ms == SETTING_PAYLOAD["detectTimeoutMs"]
    assert setting.write_events is True


def test_parse_setting_fails_loudly_on_a_missing_field() -> None:
    """A setting from a TRNRun of another version is not silently accepted."""
    payload = {key: value for key, value in SETTING_PAYLOAD.items() if key != "pollMs"}

    with pytest.raises(KeyError, match="pollMs"):
        _ = parse_setting(payload)


def test_events_are_immutable() -> None:
    event = StatusEvent(SimulationStatus.RUNNING)

    with pytest.raises(FrozenInstanceError):
        type(event).__setattr__(event, "status", SimulationStatus.DONE)
    assert SettingEvent.__dataclass_params__.frozen  # pyright: ignore[reportAttributeAccessIssue]
