# ruff: noqa: D103, S101

import trnrun
from trnrun.config import SimulationConfig
from trnrun.manager import SimulationManager
from trnrun.simulation import Simulation


def test_package_metadata() -> None:
    assert trnrun.__version__ == "0.5.0"
    assert trnrun.__all__ == ["SimulationConfig", "SimulationManager", "Simulation"]


def test_public_classes_are_reexported() -> None:
    assert trnrun.SimulationConfig is SimulationConfig
    assert trnrun.SimulationManager is SimulationManager
    assert trnrun.Simulation is Simulation
