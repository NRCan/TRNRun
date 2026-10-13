# ruff: noqa: S101

from __future__ import annotations

import runpy
import sys
from collections.abc import Callable
from pathlib import Path
from types import ModuleType
from typing import cast
from unittest.mock import MagicMock, Mock

import pytest

import trnrun
from trnrun import SimulationReply, SimulationState

EXAMPLE = Path(__file__).resolve().parents[1] / "examples" / "example_gui.py"


@pytest.fixture
def gui(monkeypatch: pytest.MonkeyPatch) -> tuple[Callable[[], None], Mock, MagicMock, list[MagicMock]]:
    """Load the GUI with fake widgets and a client, without opening a window."""
    root = Mock()
    labels = [MagicMock(), MagicMock(), MagicMock()]
    tkinter = ModuleType("tkinter")
    monkeypatch.setattr(tkinter, "Tk", Mock(return_value=root), raising=False)
    monkeypatch.setattr(tkinter, "Label", Mock(side_effect=labels), raising=False)
    monkeypatch.setitem(sys.modules, "tkinter", tkinter)
    client = MagicMock()
    client.__enter__.return_value = client
    client.exit_error.return_value = None
    monkeypatch.setattr(trnrun, "DaemonClient", Mock(return_value=client))
    namespace = runpy.run_path(str(EXAMPLE))
    return cast("Callable[[], None]", namespace["main"]), root, client, labels


def test_gui_polls_changes_until_all_runs_finish(
    gui: tuple[Callable[[], None], Mock, MagicMock, list[MagicMock]],
) -> None:
    """The UI timer owns polling, retains final rows, and stops after completion."""
    main, root, client, labels = gui
    client.database.pull.side_effect = [
        {"1": SimulationReply(SimulationState.RUNNING)},
        {
            "1": SimulationReply(SimulationState.FINISHED, succeeded=True),
            "2": SimulationReply(SimulationState.FINISHED, error="launch failed"),
        },
    ]
    root.mainloop.side_effect = lambda: root.after.call_args.args[1]()

    main()

    assert client.add.call_count == 2
    assert [call.args[0] for call in client.add.call_args_list] == ["1", "2"]
    root.after.assert_called_once()
    assert root.after.call_args.args[0] == 500
    assert "Succeeded" in labels[0].__setitem__.call_args.args[1]
    assert "launch failed" in labels[1].__setitem__.call_args.args[1]
    labels[2].__setitem__.assert_called_once_with("text", "All runs finished.")
    client.__exit__.assert_called_once_with(None, None, None)


def test_gui_stops_polling_when_daemon_exits(
    gui: tuple[Callable[[], None], Mock, MagicMock, list[MagicMock]],
) -> None:
    """Daemon failure stays visible rather than leaving a timer polling forever."""
    main, root, client, labels = gui
    client.database.pull.return_value = {}
    client.exit_error.return_value = RuntimeError("daemon exited")

    main()

    labels[2].__setitem__.assert_called_once_with("text", "daemon exited")
    root.after.assert_not_called()


def test_gui_window_close_kills_instead_of_waiting(
    gui: tuple[Callable[[], None], Mock, MagicMock, list[MagicMock]],
) -> None:
    """Closing the window interrupts runs and never requests a graceful wait."""
    main, root, client, _labels = gui
    client.database.pull.return_value = {}
    root.mainloop.side_effect = lambda: root.protocol.call_args.args[1]()

    main()

    client.kill.assert_called_once_with()
    client.shutdown.assert_not_called()
    root.destroy.assert_called_once_with()
