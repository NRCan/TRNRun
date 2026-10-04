"""Regression tests for the Python manager and Nim runner contract."""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path

from trnrun.config import SimulationConfig
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SettingEvent,
    StatusEvent,
    parse_event,
    stream_events,
)
from trnrun.simulation import Simulation

TIMESTAMP = "2026-08-26T12:34:56"


def test_config_serializes_every_runner_option(tmp_path: Path) -> None:
    """Keep Python CLI names and values aligned with the runner parser."""
    config = SimulationConfig(
        trnrun_path=tmp_path / "trnrun.exe",
        trnexe_path=tmp_path / "TrnEXE64.exe",
        gui_visibility="minimizedAuto",
        wait_for_gui=False,
        wait_for_lst=False,
        wait_for_tmp=True,
        detect_timeout_ms=1_234,
        extra_delay_ms=25,
        poll_ms=50,
        watch_log=False,
        watch_tmp=True,
        watch_timeout_ms=5_000,
        stall_timeout_ms=3_000,
        clean_on_success=True,
        kill_on_timeout=True,
        kill_on_stall=True,
        severity="Warning",
        write_events=True,
    )

    assert config.to_cli_args() == [
        f"--trnexePath:{tmp_path / 'TrnEXE64.exe'}",
        "--guiVisibility:minimizedAuto",
        "--waitForGui:false",
        "--waitForLst:false",
        "--waitForTmp:true",
        "--detectTimeout:1234",
        "--extraDelay:25",
        "--pollMs:50",
        "--watchLog:false",
        "--watchTmp:true",
        "--watchTimeout:5000",
        "--stallTimeout:3000",
        "--clean:true",
        "--killOnTimeout:true",
        "--killOnStall:true",
        "--severity:Warning",
        "--writeEvents:true",
    ]


def test_parses_every_runner_event_kind() -> None:
    """Verify all current runner payloads map to typed manager events."""
    setting_payload = {
        "kind": "SETTING",
        "timestamp": TIMESTAMP,
        "trnexePath": r"C:\TRNSYS18\Exe\TrnEXE64.exe",
        "guiVisibility": "hidden",
        "waitForGui": True,
        "waitForLst": True,
        "waitForTmp": False,
        "detectTimeoutMs": 300_000,
        "extraDelayMs": 0,
        "watchLog": True,
        "watchTmp": False,
        "watchTimeoutMs": 0,
        "stallTimeoutMs": 0,
        "pollMs": 100,
        "cleanOnSuccess": False,
        "killOnTimeout": False,
        "killOnStall": False,
        "severity": "Notice",
        "writeEvents": False,
        "seq": 1,
    }
    payloads = [
        setting_payload,
        {"kind": "STATUS", "timestamp": TIMESTAMP, "status": "RUNNING", "seq": 2},
        {"kind": "CONFIG", "timestamp": TIMESTAMP, "start": 0, "stop": 8_760, "step": 1, "seq": 3},
        {
            "kind": "PROGRESS",
            "timestamp": TIMESTAMP,
            "time": 2_190.5,
            "percent": 0.25,
            "elapsed": 1_500.0,
            "eta": 4_500.0,
            "seq": 4,
        },
        {
            "kind": "LOG",
            "timestamp": TIMESTAMP,
            "severity": "Warning",
            "time": 2_190.5,
            "unitID": 7,
            "typeID": 56,
            "messageCode": 123,
            "message": "Example warning",
            "information": "Example details",
            "seq": 5,
        },
    ]

    events = [parse_event(json.dumps(payload)) for payload in payloads]

    assert events == [
        SettingEvent(
            timestamp=TIMESTAMP,
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
        ),
        StatusEvent(status="RUNNING", timestamp=TIMESTAMP),
        ConfigEvent(start=0.0, stop=8_760.0, step=1.0, timestamp=TIMESTAMP),
        ProgressEvent(time=2_190.5, percent=0.25, elapsed=1_500.0, eta=4_500.0, timestamp=TIMESTAMP),
        LogEvent(
            severity="Warning",
            timestamp=TIMESTAMP,
            time=2_190.5,
            unit_id=7,
            type_id=56,
            message_code=123,
            message="Example warning",
            information="Example details",
        ),
    ]


def test_stream_skips_runner_diagnostics_without_losing_events() -> None:
    """Match production handling of stderr merged into runner stdout."""
    lines = [
        "Warning: orphan guard unavailable\n",
        json.dumps({"kind": "STATUS", "timestamp": TIMESTAMP, "status": "RUNNING", "seq": 1}),
        "\n",
        json.dumps({"kind": "STATUS", "timestamp": TIMESTAMP, "status": "DONE", "seq": 2}),
    ]

    assert list(stream_events(lines, skip_invalid=True)) == [
        StatusEvent(status="RUNNING", timestamp=TIMESTAMP),
        StatusEvent(status="DONE", timestamp=TIMESTAMP),
    ]


def test_simulation_folds_runner_events() -> None:
    """Keep event-state and success semantics stable for manager consumers."""
    simulation = Simulation("example.dck", SimulationConfig(), max_log_events=1)
    simulation.apply(StatusEvent(status="RUNNING", timestamp=TIMESTAMP))
    simulation.apply(ConfigEvent(start=0.0, stop=1.0, step=0.25, timestamp=TIMESTAMP))
    simulation.apply(ProgressEvent(time=0.5, percent=0.5, elapsed=100.0, eta=100.0, timestamp=TIMESTAMP))
    simulation.apply(LogEvent(severity="Notice", timestamp=TIMESTAMP, message="first"))
    simulation.apply(LogEvent(severity="Warning", timestamp=TIMESTAMP, message="second"))

    snapshot = simulation.snapshot()
    assert snapshot.status == StatusEvent(status="RUNNING", timestamp=TIMESTAMP)
    assert snapshot.config_event == ConfigEvent(start=0.0, stop=1.0, step=0.25, timestamp=TIMESTAMP)
    assert snapshot.progress == ProgressEvent(
        time=0.5,
        percent=0.5,
        elapsed=100.0,
        eta=100.0,
        timestamp=TIMESTAMP,
    )
    assert simulation.logs == [LogEvent(severity="Warning", timestamp=TIMESTAMP, message="second")]
    assert snapshot.notices == 1
    assert snapshot.warnings == 1
    assert snapshot.log_count == 2


def test_bundled_runner_end_to_end(tmp_path: Path) -> None:
    """Exercise manager invocation, runner JSONL, state folding, and exit handling."""
    if os.name != "nt":
        return

    deck_path = tmp_path / "smoke.dck"
    _ = deck_path.write_text("# Valid empty Python script used as a fake deck.\n", encoding="utf-8")
    config = SimulationConfig(
        trnexe_path=Path(sys.executable),
        wait_for_gui=False,
        wait_for_lst=False,
        wait_for_tmp=False,
        detect_timeout_ms=1_000,
        watch_log=False,
        watch_tmp=False,
        watch_timeout_ms=5_000,
        poll_ms=10,
    )
    simulation = Simulation(deck_path, config)

    simulation.run()

    assert simulation.error is None
    assert simulation.exit_code == 0
    assert simulation.status is not None
    assert simulation.status.status == "DONE"
    assert simulation.setting_event is not None
    assert simulation.setting_event.detect_timeout_ms == 1_000
    assert simulation.setting_event.poll_ms == 10
    assert simulation.succeeded
