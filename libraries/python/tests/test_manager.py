# ruff: noqa: S101, SLF001

from __future__ import annotations

import json
import logging
from dataclasses import dataclass
from pathlib import Path
from unittest.mock import Mock, call

import pytest

import trnrun.manager as manager_module
from trnrun.config import SimulationConfig
from trnrun.display import Display
from trnrun.events import SimulationStatus, StatusEvent
from trnrun.manager import SimulationManager
from trnrun.process import QueueProcess
from trnrun.simulation import Simulation

TIMESTAMP = "2026-01-02T03:04:05Z"


@dataclass
class Harness:
    """Mocks surrounding one manager instance."""

    manager: SimulationManager
    process: Mock
    display: Mock
    queue_factory: Mock
    display_factory: Mock


@pytest.fixture
def harness(monkeypatch: pytest.MonkeyPatch) -> Harness:
    """Construct a manager with process and display boundaries replaced."""
    process = Mock(spec=QueueProcess)
    process.wait.return_value = 0
    display = Mock(spec=Display)
    queue_factory = Mock(return_value=process)
    display_factory = Mock(return_value=display)
    monkeypatch.setattr(manager_module, "QueueProcess", queue_factory)
    monkeypatch.setattr(manager_module, "create_display", display_factory)
    manager = SimulationManager(max_concurrent=3, refresh_interval=0.25, trnrunq_path="mock-queue.exe")
    return Harness(manager, process, display, queue_factory, display_factory)


@pytest.fixture
def valid_inputs(tmp_path: Path) -> tuple[Path, SimulationConfig]:
    """Create harmless files satisfying submission validation."""
    deck = tmp_path / "model.dck"
    runner = tmp_path / "trnrun.exe"
    trnexe = tmp_path / "TrnEXE64.exe"
    for path in (deck, runner, trnexe):
        path.write_text("fixture", encoding="utf-8")
    return deck, SimulationConfig(trnrun_path=runner, trnexe_path=trnexe, watch_tmp=True)


def stream(run_id: str, kind: str, **payload: object) -> str:
    """Encode one tagged queue stream line."""
    return json.dumps({"runID": run_id, "kind": kind, "timestamp": TIMESTAMP, **payload})


def accepted(run_id: str) -> str:
    """Encode queue acceptance."""
    return stream(run_id, "QUEUE", event="ACCEPTED")


def completed(run_id: str, exit_code: int | None = 0) -> str:
    """Encode queue completion."""
    return stream(run_id, "QUEUE", event="COMPLETED", exitCode=exit_code)


def test_constructor_selects_display_and_starts_mocked_queue(harness: Harness) -> None:
    """The manager delegates its refresh interval to automatic display selection."""
    harness.queue_factory.assert_called_once_with("mock-queue.exe", 3)
    harness.display_factory.assert_called_once_with(0.25)

    second_display = Mock(spec=Display)
    harness.display_factory.return_value = second_display
    second = SimulationManager(
        max_concurrent=1,
        refresh_interval=2.0,
        trnrunq_path=Path("second.exe"),
    )

    assert second._display is second_display
    harness.queue_factory.assert_called_with(Path("second.exe"), 1)
    harness.display_factory.assert_called_with(2.0)


def test_add_validates_copy_sends_request_and_routes_until_acceptance(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    caplog: pytest.LogCaptureFixture,
) -> None:
    """Submission ignores noise and unrelated lifecycle while folding runner updates."""
    deck, original_config = valid_inputs
    malformed = stream("1", "STATUS")
    unknown_status = stream("1", "STATUS", status="FUTURE")
    harness.process.read_line.side_effect = [
        "native diagnostic output\n",
        malformed,
        unknown_status,
        accepted("999"),
        stream("1", "QUEUE", event="ENQUEUED"),
        stream("1", "STATUS", status="RUNNING", message="launched"),
        accepted("1"),
    ]

    with caplog.at_level(logging.DEBUG, logger="trnrun.manager"):
        simulation = harness.manager.add(deck, original_config)

    assert simulation.id == 1
    assert simulation.deck_path == deck.absolute()
    assert simulation.config is not original_config
    assert simulation.status == StatusEvent(SimulationStatus.RUNNING, TIMESTAMP, "launched")
    assert simulation.status is not None
    assert simulation.status.status is SimulationStatus.RUNNING
    assert simulation.is_accepted
    assert harness.manager.simulations == [simulation]
    assert harness.manager._active == {"1": simulation}
    assert harness.process.send.call_args == call(
        {
            "runID": "1",
            "deckFile": str(deck.absolute()),
            "runnerPath": str(simulation.config.trnrun_path),
            "runnerArgs": simulation.config.to_cli_args(),
        },
    )
    harness.display.refresh.assert_called_once_with()
    harness.display.simulation_started.assert_called_once_with(simulation)
    assert caplog.text.count("dropped malformed queue line") == 2
    assert "unknown simulation status 'FUTURE'" in caplog.text


def test_follow_routes_updates_deduplicates_acceptance_and_completes(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Follow yields meaningful routed updates through queue completion."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1")]
    simulation = harness.manager.add(deck, config)
    harness.process.read_line.side_effect = [
        accepted("1"),
        stream("1", "PROGRESS", time=5, percent=0.5, elapsed=1000, eta=1000),
        stream("1", "STATUS", status="DONE"),
        completed("1", exit_code=9),
    ]

    updates = list(harness.manager.follow())

    assert updates == [simulation, simulation, simulation]
    assert simulation.progress is not None
    assert simulation.progress.percent == 0.5
    assert simulation.status is not None
    assert simulation.status.status is SimulationStatus.DONE
    assert simulation.completion_event is not None
    assert simulation.completion_event.exit_code == 9
    assert simulation.succeeded
    assert harness.manager.succeeded == [simulation]
    assert harness.manager.failed == []
    assert harness.manager._active == {}
    harness.display.simulation_started.assert_called_once_with(simulation)
    assert harness.display.refresh.call_count == 2
    harness.display.simulation_finished.assert_called_once_with(simulation)


def test_follow_for_one_filters_yields_but_updates_other_runs(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Targeted follow yields one run while keeping interleaved runs current."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1")]
    first = harness.manager.add(deck, config)
    harness.process.read_line.side_effect = [accepted("2")]
    second = harness.manager.add(deck, config)
    harness.process.read_line.side_effect = [
        stream("2", "STATUS", status="RUNNING"),
        stream("1", "PROGRESS", time=5, percent=0.5, elapsed=1000, eta=1000),
        stream("2", "PROGRESS", time=2, percent=0.2, elapsed=500, eta=2000),
        completed("1"),
        completed("2"),
    ]

    updates = list(harness.manager.follow(first))

    assert updates == [first, first]
    assert first.is_finished
    assert not second.is_finished
    assert second.status is not None
    assert second.status.status is SimulationStatus.RUNNING
    assert second.progress is not None
    assert second.progress.percent == 0.2

    assert list(harness.manager.follow()) == [second]
    assert second.is_finished


def test_result_lists_use_acceptance_order_and_return_snapshots(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Manager results classify all completed outcomes without trusting exit code."""
    deck, config = valid_inputs
    simulations: list[Simulation] = []
    for run_id in ("1", "2", "3"):
        harness.process.read_line.side_effect = [accepted(run_id)]
        simulations.append(harness.manager.add(deck, config))

    snapshot = harness.manager.simulations
    snapshot.clear()
    harness.process.read_line.side_effect = [
        stream("2", "STATUS", status="ERROR"),
        completed("2"),
        completed("3", exit_code=None),
        stream("1", "STATUS", status="DONE"),
        completed("1", exit_code=17),
    ]

    harness.manager.wait()

    assert harness.manager.simulations == simulations
    assert harness.manager.succeeded == [simulations[0]]
    assert harness.manager.failed == [simulations[1], simulations[2]]


def test_wait_for_one_processes_other_runs_and_returns_at_target(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A targeted wait folds interleaved updates but leaves later work queued."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1")]
    first = harness.manager.add(deck, config)
    harness.process.read_line.side_effect = [accepted("2")]
    second = harness.manager.add(deck, config)
    harness.process.read_line.side_effect = [
        stream("2", "STATUS", status="RUNNING"),
        completed("1"),
        completed("2"),
    ]

    harness.manager.wait(first)

    assert first.is_finished
    assert not second.is_finished
    assert second.status is not None
    assert second.status.status is SimulationStatus.RUNNING
    assert harness.manager._active == {"2": second}

    harness.manager.wait(first)
    assert harness.process.read_line.call_count == 4

    harness.manager.wait()
    assert second.is_finished
    assert harness.manager._active == {}


def test_wait_and_follow_reject_simulation_from_another_manager(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Ownership is checked by identity before attempting any queue read."""
    deck, config = valid_inputs
    outsider = Simulation(deck, config, sim_id=1)

    with pytest.raises(ValueError, match="does not belong"):
        harness.manager.wait(outsider)
    with pytest.raises(ValueError, match="does not belong"):
        _ = list(harness.manager.follow(outsider))

    harness.process.read_line.assert_not_called()


def test_add_rejects_invalid_paths_without_sending(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    tmp_path: Path,
) -> None:
    """Deck and executable validation fails before a queue request is sent."""
    deck, config = valid_inputs

    with pytest.raises(FileNotFoundError, match="Deck file not found"):
        harness.manager.add(tmp_path / "missing.dck", config)

    invalid_config = SimulationConfig(trnrun_path=tmp_path / "missing.exe", trnexe_path=config.trnexe_path)
    with pytest.raises(FileNotFoundError, match="TRNRun executable not found"):
        harness.manager.add(deck, invalid_config)

    harness.process.send.assert_not_called()
    assert harness.manager.simulations == []
    assert harness.manager._active == {}


def test_premature_eof_during_add_reports_outstanding_run(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """EOF cannot silently convert an unaccepted request into a result."""
    deck, config = valid_inputs
    harness.process.read_line.return_value = None

    with pytest.raises(RuntimeError, match="closed before accepting or completing run IDs: 1"):
        harness.manager.add(deck, config)

    assert harness.manager._queue_eof
    assert list(harness.manager._active) == ["1"]
    assert harness.manager.simulations == []


def test_reading_eof_is_normal_when_no_runs_are_active(harness: Harness) -> None:
    """An idle EOF marks the stream drained and returns no update."""
    harness.process.read_line.return_value = None

    assert harness.manager._read_next_update() is None
    assert harness.manager._queue_eof


def test_display_errors_propagate_from_lifecycle_routing(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Manager state is updated before a display callback failure escapes."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1")]
    harness.display.simulation_started.side_effect = RuntimeError("display failed")

    with pytest.raises(RuntimeError, match="display failed"):
        harness.manager.add(deck, config)

    simulation = harness.manager.simulations[0]
    assert simulation.is_accepted
    assert harness.manager._active == {"1": simulation}


def test_shutdown_closes_drains_and_waits_only_after_eof(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Shutdown drains completion before reaping the mocked queue process."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1")]
    simulation = harness.manager.add(deck, config)
    harness.process.reset_mock()
    harness.process.wait.return_value = 0
    harness.process.read_line.side_effect = [
        stream("1", "STATUS", status="DONE"),
        completed("1"),
        None,
    ]

    harness.manager.shutdown()

    assert simulation.succeeded
    assert harness.manager._queue_eof
    assert harness.process.method_calls == [
        call.close(),
        call.read_line(),
        call.read_line(),
        call.read_line(),
        call.wait(),
    ]


def test_shutdown_reports_nonzero_queue_exit_after_clean_eof(harness: Harness) -> None:
    """A drained queue process failure is surfaced with its exit code."""
    harness.process.read_line.return_value = None
    harness.process.wait.return_value = 7

    with pytest.raises(RuntimeError, match="queue exited with code 7"):
        harness.manager.shutdown()

    assert harness.process.method_calls == [call.close(), call.read_line(), call.wait()]


def test_shutdown_preserves_premature_eof_error_and_still_reaps(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Outstanding-run EOF takes precedence over the process exit code."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1")]
    harness.manager.add(deck, config)
    harness.process.reset_mock()
    harness.process.read_line.side_effect = None
    harness.process.read_line.return_value = None
    harness.process.wait.return_value = 13

    with pytest.raises(RuntimeError, match="closed before accepting or completing run IDs: 1"):
        harness.manager.shutdown()

    assert harness.process.method_calls == [call.close(), call.read_line(), call.wait()]
    assert list(harness.manager._active) == ["1"]


def test_context_manager_returns_itself_and_shuts_down(harness: Harness) -> None:
    """Leaving a manager context performs the normal empty drain."""
    harness.process.read_line.return_value = None

    with harness.manager as entered:
        assert entered is harness.manager

    harness.process.close.assert_called_once_with()
    harness.process.wait.assert_called_once_with()
