"""Tests for the ``trnrun`` package exports."""

import tomllib
from pathlib import Path

import trnrun
from trnrun import core
from trnrun.core.daemon import DEFAULT_TRNRUN, DEFAULT_TRNRUND


def test_every_export_resolves() -> None:
    """Keep ``__all__`` in step with what the packages define."""
    for package in (trnrun, core):
        for name in package.__all__:
            assert getattr(package, name) is not None, f"{package.__name__}.{name}"


def test_the_core_is_importable_from_the_top() -> None:
    """Give applications every core name from ``import trnrun``, as the same objects."""
    for name in core.__all__:
        assert getattr(trnrun, name) is getattr(core, name), name


def test_bundled_executables_are_in_the_package_bin() -> None:
    """Look for the bundled executables in ``trnrun/bin``, where ``nimble deploy`` copies them."""
    bin_dir = Path(trnrun.__file__).parent / "bin"

    assert bin_dir / "trnrun.exe" == DEFAULT_TRNRUN
    assert bin_dir / "trnrund.exe" == DEFAULT_TRNRUND


def test_version_is_the_package_version() -> None:
    """Read the version hatch builds from, in the ``major.minor.patch`` form."""
    pyproject = tomllib.loads((Path(__file__).parents[1] / "pyproject.toml").read_text(encoding="utf-8"))

    assert pyproject["tool"]["hatch"]["version"]["path"] == "trnrun/__init__.py"
    assert [part.isdigit() for part in trnrun.__version__.split(".")] == [True, True, True]
