# ruff: noqa: D103, S101

from dataclasses import FrozenInstanceError

import pytest

from trnrun import SimulationState as ExportedSimulationState
from trnrun import SimulationStatus as ExportedSimulationStatus
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SettingEvent,
    SimulationState,
    SimulationStatus,
    SimulationUpdate,
    StatusEvent,
    parse_log,
    parse_simulation_update,
)

# Captured from trnrund running a fake TRNRun.
DAEMON_SIMULATION: dict[str, object] = {
    "runId": "1",
    "deckFile": r"C:\models\done-a.dck",
    "trnrunArgs": ["--watchTmp:true"],
    "state": "FINISHED",
    "exitCode": 0,
    "error": "",
    "setting": None,
    "status": {"status": "DONE", "message": "Completed"},
    "config": None,
    "progress": {"time": 1.0, "percent": 0.1, "elapsedMs": 20.0, "etaMs": 180.0},
    "notices": 1,
    "warnings": 0,
    "fatals": 0,
    "succeeded": True,
}
DAEMON_LOG: dict[str, object] = {
    "severity": "Notice",
    "time": 1.0,
    "unitId": None,
    "typeId": None,
    "messageCode": None,
    "message": "Started",
    "information": None,
}
SETTING_PAYLOAD: dict[str, object] = {
    "trnexePath": r"C:\TRNSYS18\Exe\TrnEXE64.exe",
    "guiVisibility": "hidden",
    "waitForGui": True,
    "waitForLst": False,
    "waitForTmp": True,
    "detectTimeoutMs": 300_000,
    "extraDelayMs": 25,
    "watchLog": True,
    "watchTmp": False,
    "watchTimeoutMs": 1_000,
    "stallTimeoutMs": 2_000,
    "pollMs": 100,
    "cleanOnSuccess": False,
    "killOnTimeout": True,
    "killOnStall": False,
    "severity": "Warning",
    "writeEvents": True,
}


def test_simulation_status_has_exact_native_values_and_is_exported() -> None:
    expected = ["PENDING", "LAUNCHING", "RUNNING", "DONE", "CANCELLED", "ERROR", "TIMEOUT", "STALLED"]

    assert [status.name for status in SimulationStatus] == expected
    assert [status.value for status in SimulationStatus] == expected
    assert ExportedSimulationStatus is SimulationStatus


def test_simulation_state_has_exact_daemon_values_and_is_exported() -> None:
    assert [state.value for state in SimulationState] == ["QUEUED", "ACCEPTED", "RUNNING", "FINISHED"]
    assert ExportedSimulationState is SimulationState


def test_parse_simulation_update_reads_daemon_state() -> None:
    assert parse_simulation_update(DAEMON_SIMULATION) == SimulationUpdate(
        state=SimulationState.FINISHED,
        exit_code=0,
        error="",
        succeeded=True,
        status=StatusEvent(SimulationStatus.DONE, "Completed"),
        progress=ProgressEvent(1.0, 0.1, 20.0, 180.0),
        notices=1,
    )


def test_update_log_count_totals_severities() -> None:
    update = parse_simulation_update({**DAEMON_SIMULATION, "notices": 3, "warnings": 2, "fatals": 1})

    assert (update.notices, update.warnings, update.fatals, update.log_count) == (3, 2, 1, 6)


def test_parse_simulation_update_reads_unlaunched_run() -> None:
    payload = {**DAEMON_SIMULATION, "exitCode": None, "error": "launch failed", "succeeded": False}

    update = parse_simulation_update(payload)

    assert update.exit_code is None
    assert update.error == "launch failed"
    assert not update.succeeded


@pytest.mark.parametrize(
    ("field", "payload", "expected"),
    [
        ("status", {"status": "RUNNING", "message": "started"}, StatusEvent(SimulationStatus.RUNNING, "started")),
        (
            "progress",
            {"time": 2.0, "percent": 0.25, "elapsedMs": 1500.0, "etaMs": 4500.5},
            ProgressEvent(2.0, 0.25, 1500.0, 4500.5),
        ),
        ("config", {"start": 0.0, "stop": 8760.0, "step": 0.25}, ConfigEvent(0.0, 8760.0, 0.25)),
        (
            "setting",
            SETTING_PAYLOAD,
            SettingEvent(
                trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe",
                gui_visibility="hidden",
                wait_for_gui=True,
                wait_for_lst=False,
                wait_for_tmp=True,
                detect_timeout_ms=300_000,
                extra_delay_ms=25,
                watch_log=True,
                watch_tmp=False,
                watch_timeout_ms=1_000,
                stall_timeout_ms=2_000,
                poll_ms=100,
                clean_on_success=False,
                kill_on_timeout=True,
                kill_on_stall=False,
                severity="Warning",
                write_events=True,
            ),
        ),
    ],
)
def test_parse_simulation_update_reads_nested_events(field: str, payload: dict[str, object], expected: object) -> None:
    update = parse_simulation_update({**DAEMON_SIMULATION, field: payload})

    assert getattr(update, field) == expected


def test_parse_log_reads_daemon_entry() -> None:
    assert parse_log(DAEMON_LOG) == LogEvent("Notice", 1.0, message="Started")


def test_parse_log_reads_every_field() -> None:
    entry = {**DAEMON_LOG, "severity": "Fatal", "unitId": 3, "typeId": 56, "messageCode": 42, "information": "x"}

    assert parse_log(entry) == LogEvent("Fatal", 1.0, 3, 56, 42, "Started", "x")


@pytest.mark.parametrize(
    ("changes", "error"),
    [
        ({"state": "DONE"}, ValueError),
        ({"status": {"status": "FUTURE", "message": ""}}, ValueError),
        ({"progress": {"time": 1.0}}, KeyError),
    ],
)
def test_mismatched_reply_fails_loudly(changes: dict[str, object], error: type[Exception]) -> None:
    """A reply from a daemon of another version is not silently accepted."""
    with pytest.raises(error):
        _ = parse_simulation_update({**DAEMON_SIMULATION, **changes})


def test_events_are_immutable() -> None:
    event = StatusEvent(SimulationStatus.RUNNING)

    with pytest.raises(FrozenInstanceError):
        type(event).__setattr__(event, "status", SimulationStatus.DONE)
