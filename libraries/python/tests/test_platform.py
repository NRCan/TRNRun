"""Path conversion for trnrund on each platform, and the Wine environment; none of it needs Wine."""

import subprocess
import warnings
from pathlib import Path

import pytest

from trnrun import SimulationSettings, _platform
from trnrun._platform import from_trnrund, to_trnrund, warn_if_old_wine, wine_env


@pytest.fixture
def off_windows(monkeypatch: pytest.MonkeyPatch) -> None:
    """Convert paths as off Windows, whatever the platform."""
    monkeypatch.setattr(_platform, "ON_WINDOWS", False)


@pytest.mark.usefixtures("off_windows")
def test_from_trnrund_maps_z_to_the_root() -> None:
    """Wine maps Z: to /, whatever the case and the separators."""
    assert from_trnrund("Z:\\home\\me\\my decks\\a.dck").as_posix() == "/home/me/my decks/a.dck"
    assert from_trnrund("z:/mnt/c/a.dck").as_posix() == "/mnt/c/a.dck"


@pytest.mark.usefixtures("off_windows")
def test_from_trnrund_maps_other_drives_through_the_prefix(monkeypatch: pytest.MonkeyPatch) -> None:
    """C: and the other drives live under the prefix's dosdevices."""
    monkeypatch.setenv("WINEPREFIX", "/home/me/.wine-trnsys")
    expected = "/home/me/.wine-trnsys/dosdevices/c:/TRNSYS18/Exe/TrnEXE64.exe"
    assert from_trnrund("C:\\TRNSYS18\\Exe\\TrnEXE64.exe").as_posix() == expected


@pytest.mark.usefixtures("off_windows")
def test_from_trnrund_defaults_to_home_prefix(monkeypatch: pytest.MonkeyPatch) -> None:
    """Without WINEPREFIX, the prefix is ~/.wine, as for Wine itself."""
    monkeypatch.delenv("WINEPREFIX", raising=False)
    monkeypatch.setenv("HOME", "/home/me")
    monkeypatch.setenv("USERPROFILE", "/home/me")  # Path.home reads this one on Windows.
    assert from_trnrund("D:\\x.dck").as_posix() == "/home/me/.wine/dosdevices/d:/x.dck"


@pytest.mark.usefixtures("off_windows")
def test_to_trnrund_keeps_windows_paths() -> None:
    """Off Windows, a path already in Windows form names a file in the prefix and passes unchanged."""
    assert to_trnrund("C:\\TRNSYS18\\Exe\\TrnEXE64.exe") == "C:\\TRNSYS18\\Exe\\TrnEXE64.exe"


def test_wine_env_is_quiet() -> None:
    """Wine's own messages must stay out of TRNRun's events."""
    env = wine_env()
    assert env["WINEDEBUG"] == "-all"
    assert "mscoree" in env["WINEDLLOVERRIDES"]


def _fake_wine(monkeypatch: pytest.MonkeyPatch, output: str) -> None:
    """Make ``wine --version`` print ``output``, with a fresh version check."""

    def run(args: list[str], **_: object) -> subprocess.CompletedProcess[str]:
        return subprocess.CompletedProcess(args, 0, stdout=output)

    monkeypatch.setattr(_platform.subprocess, "run", run)
    warn_if_old_wine.cache_clear()


@pytest.mark.parametrize("output", ["wine-9.0 (Ubuntu 9.0~repack-4build3)\n", "wine-8.0.1\n"])
def test_old_wine_warns(monkeypatch: pytest.MonkeyPatch, output: str) -> None:
    """Wine before 10 runs TRNSYS about twice as slow."""
    _fake_wine(monkeypatch, output)
    with pytest.warns(RuntimeWarning, match="twice as slow"):
        warn_if_old_wine("wine")


@pytest.mark.parametrize("output", ["wine-10.0\n", "wine-11.0\n", "wine-10.0 (Staging)\n", "", "not wine\n"])
def test_recent_or_unknown_wine_is_silent(monkeypatch: pytest.MonkeyPatch, output: str) -> None:
    """Wine 10 or later, or a version that cannot be read, passes without a warning."""
    _fake_wine(monkeypatch, output)
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        warn_if_old_wine("wine")


@pytest.mark.usefixtures("off_windows")
def test_keep_awake_warns_off_windows() -> None:
    """keep_awake still reaches TRNRun, but warns that it does nothing under Wine."""
    with pytest.warns(RuntimeWarning, match="keep_awake"):
        options = SimulationSettings(keep_awake=True).to_trnrun_options()
    assert options == {"keepAwake": True}


def test_keep_awake_is_silent_on_windows(monkeypatch: pytest.MonkeyPatch) -> None:
    """On Windows, or when keep_awake is off, there is nothing to warn about."""
    monkeypatch.setattr(_platform, "ON_WINDOWS", True)
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        _ = SimulationSettings(keep_awake=True).to_trnrun_options()
    monkeypatch.setattr(_platform, "ON_WINDOWS", False)
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        _ = SimulationSettings(keep_awake=False).to_trnrun_options()


@pytest.mark.skipif(not _platform.ON_WINDOWS, reason="Windows behaviour")
def test_on_windows_paths_are_only_made_absolute(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """On Windows nothing is converted; relative paths resolve from Python's working directory."""
    monkeypatch.chdir(tmp_path)
    assert to_trnrund("a.dck") == str(tmp_path / "a.dck")
    assert from_trnrund("C:\\models\\a.dck") == Path("C:\\models\\a.dck")


@pytest.mark.skipif(_platform.ON_WINDOWS, reason="Linux behaviour")
def test_off_windows_linux_paths_go_through_z(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """A Linux path becomes its absolute Z: path, resolved from the working directory, and comes back."""
    monkeypatch.chdir(tmp_path)
    assert to_trnrund("/home/me/my decks/a.dck") == "Z:\\home\\me\\my decks\\a.dck"
    assert to_trnrund("a.dck") == "Z:" + str(tmp_path / "a.dck").replace("/", "\\")
    assert from_trnrund(to_trnrund("a.dck")) == tmp_path / "a.dck"
