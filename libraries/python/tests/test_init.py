"""Tests for the ``trnrun`` package exports."""

import tomllib
from pathlib import Path

import trnrun
from trnrun import batch


def test_every_export_resolves() -> None:
    """Keep ``__all__`` in step with what the packages define."""
    for package in (trnrun, batch):
        for name in package.__all__:
            assert getattr(package, name) is not None, f"{package.__name__}.{name}"


def test_the_simulation_manager_is_importable_from_the_top() -> None:
    """Give scripts and notebooks everything they need from ``import trnrun``."""
    assert trnrun.SimulationManager is batch.SimulationManager
    assert trnrun.Simulation is batch.Simulation


def test_version_is_the_package_version() -> None:
    """Read the version hatch builds from, in the ``major.minor.patch`` form."""
    pyproject = tomllib.loads((Path(__file__).parents[1] / "pyproject.toml").read_text(encoding="utf-8"))

    assert pyproject["tool"]["hatch"]["version"]["path"] == "trnrun/__init__.py"
    assert [part.isdigit() for part in trnrun.__version__.split(".")] == [True, True, True]
