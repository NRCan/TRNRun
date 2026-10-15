"""Tests for ``trnrun.settings``: the command-line flags passed to TRNRun and trnrund."""

from dataclasses import fields
from pathlib import Path

import pytest

from trnrun.events import SettingEvent
from trnrun.settings import DaemonSettings, SimulationSettings


# -----------------------------------------------------------------
# SimulationSettings
# -----------------------------------------------------------------
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
    assert names >= SimulationSettings._BOOLEANS


def test_simulation_settings_match_the_reported_setting_event() -> None:
    """Keep every option TRNRun reports applying settable, under the same name."""
    settable = {settings_field.name for settings_field in fields(SimulationSettings)}
    assert settable == {event_field.name for event_field in fields(SettingEvent)}


@pytest.mark.parametrize("value", [1, 0, "true", "false", None])
def test_boolean_settings_require_real_booleans(value: object) -> None:
    """Reject truthy look-alikes instead of guessing what they mean."""
    settings = SimulationSettings(watch_log=value)  # ty: ignore[invalid-argument-type]  # pyright: ignore[reportArgumentType]
    if value is None:
        assert settings.to_cli_args() == []
    else:
        with pytest.raises(TypeError, match="watch_log must be True, False or None"):
            _ = settings.to_cli_args()


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


# -----------------------------------------------------------------
# DaemonSettings
# -----------------------------------------------------------------
def test_default_daemon_settings_pass_nothing() -> None:
    """Keep trnrund's own defaults when no field is set."""
    assert DaemonSettings().to_cli_args() == []


def test_daemon_settings_serialize_every_option(tmp_path: Path) -> None:
    """Keep the trnrund flag names aligned with its parser."""
    settings = DaemonSettings(
        trnrun_path=tmp_path / "trnrun.exe",
        max_concurrent=4,
        database_path=tmp_path / "runs.sqlite3",
    )

    assert settings.to_cli_args() == [
        f"--trnrun:{tmp_path / 'trnrun.exe'}",
        "--maxConcurrent:4",
        f"--database:{tmp_path / 'runs.sqlite3'}",
    ]


def test_daemon_settings_make_paths_absolute_without_checking_them(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Resolve relative paths here, and leave checking that they exist to trnrund."""
    monkeypatch.chdir(tmp_path)

    args = DaemonSettings(trnrun_path="bin/trnrun.exe", database_path="runs.sqlite3").to_cli_args()

    assert args == [f"--trnrun:{tmp_path / 'bin' / 'trnrun.exe'}", f"--database:{tmp_path / 'runs.sqlite3'}"]


def test_every_daemon_setting_has_a_flag() -> None:
    """Fail when a field is added without its trnrund flag."""
    names = {settings_field.name for settings_field in fields(DaemonSettings)}
    assert set(DaemonSettings._FLAGS) == names
    assert names >= DaemonSettings._PATHS
