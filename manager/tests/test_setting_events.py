"""Tests for SETTING event parsing and simulation state retention."""

import json

import pytest

from trnrun.config import SimulationConfig
from trnrun.events import EventParseError, SettingEvent, parse_event
from trnrun.simulation import Simulation


def _setting_payload() -> dict[str, object]:
    return {
        "kind": "SETTING",
        "seq": 42,
        "timestamp": "2026-08-20T12:34:56",
        "trnexePath": r"C:\TRNSYS18\Exe\TrnEXE64.exe",
        "guiVisibility": "hidden",
        "waitForGui": True,
        "waitForLst": True,
        "waitForTmp": False,
        "detectTimeoutMs": 1000,
        "extraDelayMs": 250,
        "watchLog": True,
        "watchTmp": False,
        "watchTimeoutMs": 2000,
        "stallTimeoutMs": 3000,
        "pollMs": 100,
        "cleanOnSuccess": False,
        "killOnTimeout": True,
        "killOnStall": False,
        "severity": "Warning",
        "writeEvents": True,
    }


def test_parse_setting_event_maps_all_fields_and_ignores_seq() -> None:
    """SETTING wire fields are converted to the frozen Python model."""
    event = parse_event(json.dumps(_setting_payload()))

    assert event == SettingEvent(  # noqa: S101
        timestamp="2026-08-20T12:34:56",
        trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe",
        gui_visibility="hidden",
        wait_for_gui=True,
        wait_for_lst=True,
        wait_for_tmp=False,
        detect_timeout_ms=1000,
        extra_delay_ms=250,
        watch_log=True,
        watch_tmp=False,
        watch_timeout_ms=2000,
        stall_timeout_ms=3000,
        poll_ms=100,
        clean_on_success=False,
        kill_on_timeout=True,
        kill_on_stall=False,
        severity="Warning",
        write_events=True,
    )
    assert not hasattr(event, "seq")  # noqa: S101


@pytest.mark.parametrize("invalid_value", [1, 0, "true", None])
def test_parse_setting_event_requires_json_boolean(invalid_value: object) -> None:
    """Boolean setting fields reject integer, string, and null values."""
    payload = _setting_payload()
    payload["writeEvents"] = invalid_value

    with pytest.raises(EventParseError, match="field 'writeEvents' must be a boolean"):
        _ = parse_event(json.dumps(payload))


def test_simulation_retains_latest_setting_event() -> None:
    """Simulation properties and snapshots expose the latest SETTING event."""
    simulation = Simulation("example.dck", SimulationConfig())
    assert simulation.setting_event is None  # noqa: S101
    assert simulation.snapshot().setting_event is None  # noqa: S101

    first = parse_event(json.dumps(_setting_payload()))
    assert isinstance(first, SettingEvent)  # noqa: S101
    simulation.apply(first)

    updated_payload = _setting_payload()
    updated_payload["timestamp"] = "2026-08-20T12:35:00"
    updated_payload["pollMs"] = 500
    latest = parse_event(json.dumps(updated_payload))
    assert isinstance(latest, SettingEvent)  # noqa: S101
    simulation.apply(latest)

    assert simulation.setting_event == latest  # noqa: S101
    assert simulation.snapshot().setting_event == latest  # noqa: S101
