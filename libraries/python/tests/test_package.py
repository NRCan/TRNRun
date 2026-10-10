# ruff: noqa: S101

from __future__ import annotations

import subprocess
import sys
from pathlib import Path
from textwrap import dedent

import pytest

PACKAGE_ROOT = Path(__file__).resolve().parents[1]

# Run imports in fresh processes so other tests cannot mask an eager Rich import.
BLOCK_RICH = """
import sys
from importlib.abc import MetaPathFinder

class BlockRich(MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "rich" or fullname.startswith("rich."):
            raise ModuleNotFoundError("Rich is unavailable for this test", name=fullname)
        return None

sys.meta_path.insert(0, BlockRich())
"""


@pytest.mark.parametrize(
    "code",
    [
        """
        import trnrun
        from trnrun import DaemonClient, SimulationConfig, SimulationReply, SimulationState, SimulationStatus

        assert set(trnrun.__all__) == {
            "DaemonClient", "SimulationConfig", "SimulationReply", "SimulationState", "SimulationStatus",
        }
        assert not any(name.startswith("trnrun.convenience") for name in sys.modules)
        """,
        """
        from trnrun.convenience import Display, Simulation, SimulationManager

        assert "trnrun.convenience.display" not in sys.modules
        assert "trnrun.convenience.utils" not in sys.modules
        """,
        """
        from unittest.mock import Mock
        import trnrun.convenience.manager as manager_module
        from trnrun import SimulationConfig, SimulationReply, SimulationState
        from trnrun.convenience import SimulationManager

        client = Mock()
        factory = Mock(return_value=client)
        manager_module.DaemonClient = factory
        custom_display = Mock(spec=["update", "close"])
        SimulationConfig.to_cli_args = lambda self: []
        for display in (False, custom_display):
            with SimulationManager(display=display, poll_interval=3600) as manager:
                config = SimulationConfig()

                simulation = manager.add("model.dck", config)
                client.pull.return_value = {"1": SimulationReply(SimulationState.FINISHED)}
                manager._sync()
                manager.wait(timeout=0)
                assert simulation.is_finished
                assert manager.display is (None if display is False else custom_display)
        assert factory.call_count == 2
        assert client.kill.call_count == 2
        custom_display.update.assert_called_once()
        custom_display.close.assert_called_once()
        assert "trnrun.convenience.display" not in sys.modules
        """,
        """
        from unittest.mock import Mock
        import trnrun.convenience.manager as manager_module
        from trnrun.convenience import SimulationManager

        factory = Mock()
        manager_module.DaemonClient = factory
        try:
            SimulationManager()
        except ImportError as error:
            assert "trnrun[display]" in str(error)
            assert "display=False" in str(error)
        else:
            raise AssertionError("The built-in display must require Rich")
        factory.assert_not_called()
        """,
        """
        import trnrun.convenience as convenience

        try:
            convenience.ProgressDisplay
        except ImportError as error:
            assert "trnrun[display]" in str(error)
        else:
            raise AssertionError("The exported display must require Rich")
        """,
    ],
    ids=["core", "convenience", "manager-without-display-dependencies", "default-display", "display-export"],
)
def test_without_rich(code: str) -> None:
    """Core and non-display conveniences work without optional presentation dependencies."""
    result = subprocess.run(
        [sys.executable, "-c", dedent(BLOCK_RICH) + dedent(code)],
        cwd=PACKAGE_ROOT,
        capture_output=True,
        text=True,
        timeout=15,
        check=False,
    )
    assert result.returncode == 0, result.stdout + result.stderr


def test_convenience_exports() -> None:
    """The convenience namespace exposes the moved classes and rejects unknown names."""
    from trnrun import convenience  # noqa: PLC0415 - test public imports
    from trnrun.convenience.display import ProgressDisplay  # noqa: PLC0415
    from trnrun.convenience.manager import Display, SimulationManager  # noqa: PLC0415
    from trnrun.convenience.simulation import Simulation  # noqa: PLC0415

    assert convenience.Display is Display
    assert convenience.ProgressDisplay is ProgressDisplay
    assert convenience.Simulation is Simulation
    assert convenience.SimulationManager is SimulationManager
    with pytest.raises(AttributeError, match="has no attribute 'unknown'"):
        convenience.__getattr__("unknown")
