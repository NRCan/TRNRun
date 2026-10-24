"""SimulationSettings: the TRNRun flags it builds, and trnrund accepting every one."""

from dataclasses import fields
from pathlib import Path

import pytest

from tests.conftest import PYTHON, DeckWriter, requires_trnrund
from trnrun import Daemon, LogSeverity, SimulationSettings


def test_default_settings_pass_nothing() -> None:
    """No field set keeps TRNRun's own defaults."""
    assert SimulationSettings().to_cli_args() == []


def test_settings_pass_only_the_fields_set() -> None:
    """Unset fields are left out, whatever their position."""
    assert SimulationSettings(poll_ms=10, severity="Fatal").to_cli_args() == ["--pollMs:10", "--severity:Fatal"]
    assert SimulationSettings(severity=LogSeverity.WARNING).to_cli_args() == ["--severity:Warning"]


def test_every_setting_has_a_flag() -> None:
    """A field added without its TRNRun flag fails here."""
    assert set(SimulationSettings._FLAGS) == {settings_field.name for settings_field in fields(SimulationSettings)}  # pyright: ignore[reportPrivateUsage]


def test_relative_trnexe_path_is_made_absolute(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """A relative TrnEXE path resolves from Python's working directory, not trnrund's."""
    monkeypatch.chdir(tmp_path)
    (tmp_path / "TrnEXE64.exe").touch()
    assert SimulationSettings(trnexe_path="TrnEXE64.exe").to_cli_args() == [f"--trnexePath:{tmp_path / 'TrnEXE64.exe'}"]


def test_missing_trnexe_fails_before_queuing(tmp_path: Path) -> None:
    """A missing TrnEXE, or a directory, raises when the flags are built."""
    with pytest.raises(FileNotFoundError, match="TrnEXE executable not found"):
        _ = SimulationSettings(trnexe_path=tmp_path / "missing.exe").to_cli_args()
    with pytest.raises(FileNotFoundError):
        _ = SimulationSettings(trnexe_path=tmp_path).to_cli_args()


@requires_trnrund
def test_trnrund_accepts_every_setting(deck: DeckWriter) -> None:
    """Every flag passes trnrund's check of TRNRun's options, and is stored as built."""
    settings = SimulationSettings(
        trnexe_path=PYTHON,
        gui_visibility="hidden",
        wait_for_gui=False,
        wait_for_lst=False,
        wait_for_tmp=False,
        detect_timeout_ms=1_000,
        extra_delay_ms=0,
        poll_ms=10,
        watch_log=True,
        watch_tmp=True,
        watch_timeout_ms=5_000,
        stall_timeout_ms=3_000,
        clean_on_success=False,
        kill_on_timeout=True,
        kill_on_stall=True,
        severity="Warning",
        write_events=False,
    )
    assert len(settings.to_cli_args()) == len(fields(SimulationSettings))
    with Daemon(workers=1, trnrun_path=PYTHON) as daemon:
        sim_id = daemon.add(deck(), settings)
        assert daemon.get(sim_id).trnrun_args == settings.to_cli_args()
