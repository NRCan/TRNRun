# ruff: noqa: D103, S101

import json
from dataclasses import FrozenInstanceError

import pytest

from trnrun import SimulationStatus as ExportedSimulationStatus
from trnrun.events import (
    TERMINAL_STATUSES,
    ConfigEvent,
    EventParseError,
    LogEvent,
    ProgressEvent,
    QueueEvent,
    SettingEvent,
    SimulationStatus,
    StatusEvent,
    is_terminal_status,
    parse_event,
    parse_event_data,
    parse_stream_line,
)

TIMESTAMP = "2026-01-02T03:04:05.678Z"
SETTING_PAYLOAD: dict[str, object] = {
    "kind": "SETTING",
    "timestamp": TIMESTAMP,
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


@pytest.mark.parametrize(
    ("payload", "expected"),
    [
        (
            {
                "kind": "status",
                "status": "RUNNING",
                "timestamp": TIMESTAMP,
                "message": "Simulation started",
                "seq": 1,
            },
            StatusEvent(SimulationStatus.RUNNING, TIMESTAMP, "Simulation started"),
        ),
        (
            {
                "kind": "PROGRESS",
                "time": 2,
                "percent": 0.25,
                "elapsed": 1500,
                "eta": 4500.5,
                "timestamp": TIMESTAMP,
            },
            ProgressEvent(2.0, 0.25, 1500.0, 4500.5, TIMESTAMP),
        ),
        (
            {"kind": "CONFIG", "start": 0, "stop": 8760.0, "step": 0.25, "timestamp": TIMESTAMP},
            ConfigEvent(0.0, 8760.0, 0.25, TIMESTAMP),
        ),
        (
            SETTING_PAYLOAD,
            SettingEvent(
                timestamp=TIMESTAMP,
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
        (
            {
                "kind": "LOG",
                "severity": "Fatal",
                "timestamp": TIMESTAMP,
                "time": 12,
                "unitID": 3,
                "typeID": 56,
                "messageCode": 42,
                "message": "Failure",
                "information": "Details",
            },
            LogEvent("Fatal", TIMESTAMP, 12.0, 3, 56, 42, "Failure", "Details"),
        ),
        (
            {
                "kind": "QUEUE",
                "event": "completed",
                "runID": "run-123",
                "timestamp": TIMESTAMP,
                "exitCode": 0,
            },
            QueueEvent("completed", "run-123", TIMESTAMP, 0),
        ),
    ],
)
def test_parse_event_creates_typed_events(payload: dict[str, object], expected: object) -> None:
    event = parse_event(json.dumps(payload))

    assert event == expected
    if isinstance(event, StatusEvent):
        assert event.status is SimulationStatus.RUNNING


@pytest.mark.parametrize("message", [None, ""])
def test_status_message_defaults_to_empty_string(message: str | None) -> None:
    payload: dict[str, object] = {
        "kind": "STATUS",
        "status": "DONE",
        "timestamp": TIMESTAMP,
        "message": message,
    }

    event = parse_event_data(payload)

    assert event == StatusEvent(SimulationStatus.DONE, TIMESTAMP)
    assert isinstance(event, StatusEvent)
    assert event.status is SimulationStatus.DONE


def test_log_optional_fields_default_to_none() -> None:
    payload: dict[str, object] = {"kind": "LOG", "severity": "Notice", "timestamp": TIMESTAMP}

    assert parse_event_data(payload) == LogEvent("Notice", TIMESTAMP)


def test_queue_exit_code_defaults_to_none() -> None:
    payload: dict[str, object] = {
        "kind": "QUEUE",
        "event": "accepted",
        "runID": "run-1",
        "timestamp": TIMESTAMP,
    }

    assert parse_event_data(payload) == QueueEvent("accepted", "run-1", TIMESTAMP)


@pytest.mark.parametrize("line", ["", "not JSON", "{", "[1, 2, 3]", "null", '"text"'])
def test_parse_event_rejects_invalid_json_or_non_objects(line: str) -> None:
    with pytest.raises(EventParseError) as exc_info:
        _ = parse_event(line)

    expected = "event must be a JSON object" if line in {"[1, 2, 3]", "null", '"text"'} else "invalid JSON:"
    assert str(exc_info.value).startswith(expected)


@pytest.mark.parametrize(
    ("payload", "message"),
    [
        ({}, "field 'kind' must be a string"),
        ({"kind": 1}, "field 'kind' must be a string"),
        ({"kind": "future"}, "unknown event kind 'FUTURE'"),
        ({"kind": "STATUS", "timestamp": TIMESTAMP}, "field 'status' must be a string"),
        (
            {"kind": "STATUS", "status": "FUTURE", "timestamp": TIMESTAMP},
            "unknown simulation status 'FUTURE'",
        ),
        (
            {"kind": "PROGRESS", "time": True, "percent": 0, "elapsed": 0, "eta": 0, "timestamp": TIMESTAMP},
            "field 'time' must be a number",
        ),
        (
            {**SETTING_PAYLOAD, "waitForGui": 1},
            "field 'waitForGui' must be a boolean",
        ),
        (
            {
                "kind": "QUEUE",
                "event": "completed",
                "runID": "run-1",
                "timestamp": TIMESTAMP,
                "exitCode": True,
            },
            "field 'exitCode' must be an integer",
        ),
        (
            {"kind": "LOG", "severity": "Notice", "timestamp": TIMESTAMP, "message": 3},
            "field 'message' must be a string",
        ),
    ],
)
def test_parse_event_data_rejects_invalid_fields(payload: dict[str, object], message: str) -> None:
    with pytest.raises(EventParseError, match=message):
        _ = parse_event_data(payload)


def test_simulation_status_has_exact_native_values_and_is_exported() -> None:
    expected = [
        "PENDING",
        "LAUNCHING",
        "RUNNING",
        "DONE",
        "CANCELLED",
        "ERROR",
        "TIMEOUT",
        "STALLED",
    ]

    assert [status.name for status in SimulationStatus] == expected
    assert [status.value for status in SimulationStatus] == expected
    assert all(isinstance(status, SimulationStatus) for status in TERMINAL_STATUSES)
    assert ExportedSimulationStatus is SimulationStatus


@pytest.mark.parametrize("status", sorted(TERMINAL_STATUSES))
def test_terminal_statuses_are_recognized(status: SimulationStatus) -> None:
    assert is_terminal_status(status)


@pytest.mark.parametrize("status", [SimulationStatus.PENDING, SimulationStatus.LAUNCHING, SimulationStatus.RUNNING])
def test_nonterminal_statuses_are_not_terminal(status: SimulationStatus) -> None:
    assert not is_terminal_status(status)


@pytest.mark.parametrize("status", ["done", " DONE", "DONE ", "", "FUTURE"])
def test_parse_event_data_rejects_unknown_statuses(status: str) -> None:
    payload: dict[str, object] = {"kind": "STATUS", "status": status, "timestamp": TIMESTAMP}

    with pytest.raises(EventParseError, match=f"unknown simulation status '{status}'"):
        _ = parse_event_data(payload)


@pytest.mark.parametrize(
    "line",
    [
        "",
        "native diagnostic text",
        "[]",
        "{}",
        '{"kind": "STATUS", "status": "RUNNING", "timestamp": "now"}',
        '{"kind": "STATUS", "runID": 7, "status": "RUNNING", "timestamp": "now"}',
    ],
)
def test_parse_stream_line_ignores_unroutable_lines(line: str) -> None:
    assert parse_stream_line(line) is None


def test_parse_stream_line_routes_runner_event() -> None:
    line = json.dumps(
        {"kind": "STATUS", "runID": "run-9", "status": "RUNNING", "timestamp": TIMESTAMP},
    )

    parsed = parse_stream_line(line)

    assert parsed == ("run-9", StatusEvent(SimulationStatus.RUNNING, TIMESTAMP))
    assert parsed is not None
    event = parsed[1]
    assert isinstance(event, StatusEvent)
    assert event.status is SimulationStatus.RUNNING


def test_parse_stream_line_routes_queue_event() -> None:
    line = json.dumps(
        {"kind": "QUEUE", "event": "accepted", "runID": "run-9", "timestamp": TIMESTAMP},
    )

    assert parse_stream_line(line) == ("run-9", QueueEvent("accepted", "run-9", TIMESTAMP))


def test_parse_stream_line_rejects_malformed_routable_event() -> None:
    line = json.dumps({"kind": "PROGRESS", "runID": "run-9"})

    with pytest.raises(EventParseError, match="field 'time' must be a number"):
        _ = parse_stream_line(line)


def test_events_are_immutable() -> None:
    event = StatusEvent(SimulationStatus.RUNNING, TIMESTAMP)

    with pytest.raises(FrozenInstanceError):
        type(event).__setattr__(event, "status", SimulationStatus.DONE)
