# ruff: noqa: D103, S101

from pathlib import Path

import pytest

from trnrun.config import BUNDLED_TRNRUN_PATH, DEFAULT_TRNEXE_PATH, SimulationConfig

BOOLEAN_FIELDS = (
    "wait_for_gui",
    "wait_for_lst",
    "wait_for_tmp",
    "watch_log",
    "watch_tmp",
    "clean_on_success",
    "kill_on_timeout",
    "kill_on_stall",
    "write_events",
)


def test_defaults_match_runner_defaults() -> None:
    config = SimulationConfig()

    assert vars(config) == {
        "trnrun_path": BUNDLED_TRNRUN_PATH,
        "trnexe_path": DEFAULT_TRNEXE_PATH,
        "gui_visibility": "hidden",
        "wait_for_gui": True,
        "wait_for_lst": True,
        "wait_for_tmp": False,
        "detect_timeout_ms": 300_000,
        "extra_delay_ms": 0,
        "poll_ms": 100,
        "watch_log": True,
        "watch_tmp": False,
        "watch_timeout_ms": 0,
        "stall_timeout_ms": 0,
        "clean_on_success": False,
        "kill_on_timeout": False,
        "kill_on_stall": False,
        "severity": "Notice",
        "write_events": False,
    }


def test_to_cli_args_serializes_every_option(tmp_path: Path) -> None:
    trnexe_path = tmp_path / "TRNSYS executable.exe"
    config = SimulationConfig(
        trnrun_path="custom-runner.exe",
        trnexe_path=trnexe_path,
        gui_visibility="minAuto",
        wait_for_gui=False,
        wait_for_lst=False,
        wait_for_tmp=True,
        detect_timeout_ms=12_345,
        extra_delay_ms=67,
        poll_ms=8,
        watch_log=False,
        watch_tmp=True,
        watch_timeout_ms=90,
        stall_timeout_ms=123,
        clean_on_success=True,
        kill_on_timeout=True,
        kill_on_stall=True,
        severity="Fatal",
        write_events=True,
    )

    assert config.to_cli_args() == [
        f"--trnexePath:{trnexe_path.absolute()}",
        "--guiVisibility:minAuto",
        "--waitForGui:false",
        "--waitForLst:false",
        "--waitForTmp:true",
        "--detectTimeout:12345",
        "--extraDelay:67",
        "--pollMs:8",
        "--watchLog:false",
        "--watchTmp:true",
        "--watchTimeout:90",
        "--stallTimeout:123",
        "--clean:true",
        "--killOnTimeout:true",
        "--killOnStall:true",
        "--severity:Fatal",
        "--writeEvents:true",
    ]
    assert config.trnrun_path == "custom-runner.exe"
    assert config.trnexe_path == trnexe_path


@pytest.mark.parametrize("field", BOOLEAN_FIELDS)
def test_to_cli_args_rejects_non_boolean_values(field: str) -> None:
    config = SimulationConfig()
    setattr(config, field, 1)

    with pytest.raises(TypeError, match="Expected a boolean, got 1"):
        _ = config.to_cli_args()


def test_validate_accepts_files_and_stores_absolute_paths(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    runner = tmp_path / "runner.exe"
    trnexe = tmp_path / "trnexe.exe"
    runner.touch()
    trnexe.touch()
    monkeypatch.chdir(tmp_path)
    config = SimulationConfig(trnrun_path=runner.name, trnexe_path=trnexe.name)

    config.validate()

    assert config.trnrun_path == runner.absolute()
    assert config.trnexe_path == trnexe.absolute()
    assert isinstance(config.trnrun_path, Path)
    assert isinstance(config.trnexe_path, Path)


def test_validate_reports_missing_runner_first(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.chdir(tmp_path)
    config = SimulationConfig(trnrun_path="missing-runner.exe", trnexe_path="missing-trnexe.exe")

    with pytest.raises(FileNotFoundError) as exc_info:
        config.validate()

    assert exc_info.value.args == (f"TRNRun executable not found: {tmp_path / 'missing-runner.exe'}",)
    assert config.trnrun_path == "missing-runner.exe"
    assert config.trnexe_path == "missing-trnexe.exe"


def test_validate_reports_missing_trnexe_without_mutating_paths(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    runner = tmp_path / "runner.exe"
    runner.touch()
    monkeypatch.chdir(tmp_path)
    config = SimulationConfig(trnrun_path=runner.name, trnexe_path="missing-trnexe.exe")

    with pytest.raises(FileNotFoundError) as exc_info:
        config.validate()

    assert exc_info.value.args == (f"TrnEXE executable not found: {tmp_path / 'missing-trnexe.exe'}",)
    assert config.trnrun_path == runner.name
    assert config.trnexe_path == "missing-trnexe.exe"
