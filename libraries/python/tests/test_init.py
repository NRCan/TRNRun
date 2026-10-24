"""The package's public names, and its version matching the bundled executables."""

import subprocess

import trnrun
from tests.conftest import requires_trnrund
from trnrun.daemon import BIN


def test_every_public_name_exists() -> None:
    """Each name in ``__all__`` is importable from the package."""
    assert [name for name in trnrun.__all__ if not hasattr(trnrun, name)] == []


@requires_trnrund
def test_version_matches_the_bundled_executables() -> None:
    """The wheel build refuses a mismatch; this catches it before."""
    for exe in ("trnrund.exe", "trnrun.exe"):
        result = subprocess.run([BIN / exe, "--version"], check=True, capture_output=True, text=True)
        assert result.stdout.strip() == trnrun.__version__, exe
