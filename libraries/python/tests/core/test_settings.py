"""Tests for ``trnrun.core.settings``: the command-line flags passed to TRNRun."""

from dataclasses import fields
from pathlib import Path

import pytest

from tests.helpers import SETTING
from trnrun.core.settings import SimulationSettings


def test_default_simulation_settings_pass_nothing() -> None:
    """Keep TRNRun's own defaults when no field is set."""
    assert SimulationSettings().to_cli_args() == []


def test_simulation_settings_serialize_every_runner_option(tmp_path: Path) -> None:
    """Keep the Python field names, flag names and values aligned with TRNRun's parser."""
    trnexe = tmp_path / "TrnEXE64.exe"
    trnexe.touch()
    settings = SimulationSettings(
        trnexe_path=trnexe,
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

    assert settings.to_cli_args() == [
        f"--trnexePath:{trnexe}",
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


def test_simulation_settings_pass_only_the_fields_set() -> None:
    """Leave unset fields out, whatever their position."""
    assert SimulationSettings(poll_ms=10, severity="Fatal").to_cli_args() == ["--pollMs:10", "--severity:Fatal"]


def test_every_simulation_setting_has_a_flag() -> None:
    """Fail when a field is added without its TRNRun flag."""
    names = {settings_field.name for settings_field in fields(SimulationSettings)}
    assert set(SimulationSettings._FLAGS) == names


def test_every_reported_setting_is_settable() -> None:
    """Keep every option TRNRun reports applying settable."""
    assert len(SimulationSettings._FLAGS) == len(SETTING)


def test_relative_trnexe_path_is_made_absolute(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Resolve a relative TrnEXE path from Python's working directory, not the daemon's."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / "TrnEXE64.exe").touch()

    assert SimulationSettings(trnexe_path="TrnEXE64.exe").to_cli_args() == [f"--trnexePath:{tmp_path / 'TrnEXE64.exe'}"]


def test_missing_trnexe_fails_before_queuing(tmp_path: Path) -> None:
    """Report a missing TRNSYS installation when the arguments are built."""
    with pytest.raises(FileNotFoundError, match="TrnEXE executable not found"):
        _ = SimulationSettings(trnexe_path=tmp_path / "missing.exe").to_cli_args()


def test_trnexe_path_must_be_a_file(tmp_path: Path) -> None:
    """Reject a directory given as the TrnEXE path."""
    with pytest.raises(FileNotFoundError):
        _ = SimulationSettings(trnexe_path=tmp_path).to_cli_args()
