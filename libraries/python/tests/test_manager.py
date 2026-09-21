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
from trnrun.events import StatusEvent
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
    harness.process.read_line.side_effect = [
        "native diagnostic output\n",
        malformed,
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
    assert simulation.status == StatusEvent("RUNNING", TIMESTAMP, "launched")
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
    assert "dropped malformed queue line" in caplog.text


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
    assert simulation.status.status == "DONE"
    assert simulation.completion_event is not None
    assert simulation.completion_event.exit_code == 9
    assert simulation.succeeded
    assert harness.manager.succeeded == [simulation]
    assert harness.manager.failed == []
    assert harness.manager._active == {}
    harness.display.simulation_started.assert_called_once_with(simulation)
    assert harness.display.refresh.call_count == 2
    harness.display.simulation_finished.assert_called_once_with(simulation)


def test_lifecycle_callbacks_observe_updated_state_and_tracking(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Display notifications see both simulation state and manager tracking updated."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [
        accepted("1"),
        accepted("1"),
        stream("1", "STATUS", status="DONE"),
        completed("1"),
    ]

    def on_started(simulation: Simulation) -> None:
        assert simulation.is_accepted
        assert not simulation.is_finished
        assert harness.manager.simulations == [simulation]
        assert harness.manager._active == {"1": simulation}

    def on_finished(simulation: Simulation) -> None:
        assert simulation.is_finished
        assert simulation.succeeded
        assert harness.manager.simulations == [simulation]
        assert harness.manager._active == {}

    harness.display.simulation_started.side_effect = on_started
    harness.display.simulation_finished.side_effect = on_finished

    simulation = harness.manager.add(deck, config)
    harness.manager.wait(simulation)

    harness.display.simulation_started.assert_called_once_with(simulation)
    harness.display.simulation_finished.assert_called_once_with(simulation)
    harness.display.refresh.assert_called_once_with()


def test_follow_ignores_late_and_unknown_events_without_stopping(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Ignored events neither mutate completed runs nor end the update stream."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), accepted("2")]
    first = harness.manager.add(deck, config)
    second = harness.manager.add(deck, config)
    harness.process.read_line.side_effect = [
        stream("1", "STATUS", status="DONE"),
        completed("1"),
        accepted("1"),
        stream("1", "STATUS", status="ERROR"),
        completed("1", exit_code=9),
        accepted("999"),
        stream("2", "QUEUE", event="ENQUEUED"),
        stream("2", "STATUS", status="DONE"),
        completed("2"),
    ]

    assert list(harness.manager.follow()) == [first, first, second, second]
    assert harness.manager.simulations == [first, second]
    assert harness.manager.succeeded == [first, second]
    assert first.completion_event is not None
    assert first.completion_event.exit_code == 0
    assert harness.display.simulation_started.call_args_list == [call(first), call(second)]
    assert harness.display.simulation_finished.call_args_list == [call(first), call(second)]
    assert harness.display.refresh.call_count == 2


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
    assert second.status.status == "RUNNING"
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
    assert second.status.status == "RUNNING"
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

    assert list(harness.manager._active) == ["1"]
    assert harness.manager.simulations == []


def test_read_next_update_raises_on_eof_even_when_idle(harness: Harness) -> None:
    """Reading an update either returns a simulation or raises, never None."""
    harness.process.read_line.return_value = None

    with pytest.raises(RuntimeError, match="queue closed"):
        _ = harness.manager._read_next_update()


@pytest.mark.parametrize("finished_run", [False, True])
def test_idle_wait_and_follow_do_not_read_queue(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    *,
    finished_run: bool,
) -> None:
    """Empty and fully completed managers finish waiting without reading EOF."""
    simulation = None
    if finished_run:
        deck, config = valid_inputs
        harness.process.read_line.side_effect = [accepted("1"), completed("1")]
        simulation = harness.manager.add(deck, config)
        harness.manager.wait()

    harness.process.read_line.reset_mock(side_effect=True)
    harness.process.read_line.return_value = None

    harness.manager.wait()
    harness.manager.wait(simulation)
    assert list(harness.manager.follow()) == []
    assert list(harness.manager.follow(simulation)) == []
    harness.process.read_line.assert_not_called()


@pytest.mark.parametrize("operation", ["follow", "wait"])
def test_premature_eof_with_accepted_run_raises(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    operation: str,
) -> None:
    """Waiting must not silently finish when the queue closes with an active run."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), None]
    simulation = harness.manager.add(deck, config)

    with pytest.raises(RuntimeError, match="closed before accepting or completing run IDs: 1"):
        if operation == "follow":
            _ = list(harness.manager.follow())
        else:
            harness.manager.wait()

    assert not simulation.is_finished
    assert harness.manager._active == {"1": simulation}


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


def test_display_error_after_completion_preserves_finished_state(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A failing completion callback leaves the run completed and untracked."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), completed("1")]
    simulation = harness.manager.add(deck, config)
    harness.display.simulation_finished.side_effect = RuntimeError("display failed")

    with pytest.raises(RuntimeError, match="display failed"):
        harness.manager.wait()

    assert simulation.is_finished
    assert harness.manager._active == {}
    harness.display.simulation_finished.assert_called_once_with(simulation)


@pytest.mark.parametrize("operation", ["follow", "wait"])
@pytest.mark.parametrize("callback", ["refresh", "simulation_finished"])
def test_display_errors_outside_shutdown_stop_reading_immediately(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    operation: str,
    callback: str,
) -> None:
    """Normal pumping raises the original display error without draining or reaping."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1")]
    simulation = harness.manager.add(deck, config)
    harness.process.reset_mock()
    harness.process.read_line.side_effect = [
        stream("1", "STATUS", status="DONE"),
        completed("1"),
        None,
    ]
    display_error = RuntimeError("display failed")
    getattr(harness.display, callback).side_effect = display_error

    with pytest.raises(RuntimeError) as raised:
        _ = list(harness.manager.follow()) if operation == "follow" else harness.manager.wait()

    assert raised.value is display_error
    assert harness.process.read_line.call_count == (1 if callback == "refresh" else 2)
    assert simulation.status == StatusEvent("DONE", TIMESTAMP)
    assert simulation.is_finished == (callback == "simulation_finished")
    harness.process.shutdown.assert_not_called()


def test_shutdown_terminates_without_reading_events_or_changing_state(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Shutdown discards even buffered completion events and preserves observed state."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), stream("1", "STATUS", status="RUNNING")]
    simulation = harness.manager.add(deck, config)
    assert next(harness.manager.follow()) is simulation
    harness.process.reset_mock()
    harness.display.reset_mock()
    harness.process.read_line.side_effect = [
        stream("1", "STATUS", status="DONE"),
        completed("1"),
        None,
    ]

    harness.manager.shutdown()

    assert not simulation.is_finished
    assert simulation.status == StatusEvent("RUNNING", TIMESTAMP)
    assert harness.manager.simulations == [simulation]
    assert harness.manager.succeeded == []
    assert harness.manager.failed == []
    assert harness.process.method_calls == [call.shutdown()]
    assert harness.display.method_calls == [call.close()]


def test_explicit_wait_collects_results_before_context_cleanup(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Explicit waiting records outcomes that remain accessible after shutdown."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [
        accepted("1"),
        accepted("2"),
        stream("1", "STATUS", status="DONE"),
        completed("1"),
        stream("2", "STATUS", status="ERROR"),
        completed("2", exit_code=9),
    ]

    with harness.manager:
        first = harness.manager.add(deck, config)
        second = harness.manager.add(deck, config)
        harness.manager.wait()
        harness.process.shutdown.assert_not_called()
        harness.process.reset_mock()

    assert harness.process.method_calls == [call.shutdown()]
    assert first.is_finished
    assert second.is_finished
    for snapshot in (harness.manager.simulations, harness.manager.succeeded, harness.manager.failed):
        snapshot.clear()
    assert harness.manager.simulations == [first, second]
    assert harness.manager.succeeded == [first]
    assert harness.manager.failed == [second]


@pytest.mark.parametrize("accept_before_eof", [False, True])
def test_context_cleanup_preserves_previously_reported_eof(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    *,
    accept_before_eof: bool,
) -> None:
    """Cleanup reaps an exhausted queue without replacing an add or wait error."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), None] if accept_before_eof else [None]

    with pytest.raises(RuntimeError, match="closed before accepting or completing run IDs: 1"), harness.manager:
        harness.manager.wait(harness.manager.add(deck, config))

    harness.process.shutdown.assert_called_once_with()
    harness.display.close.assert_called_once_with()
    assert harness.process.read_line.call_count == (2 if accept_before_eof else 1)


def test_repeated_shutdown_and_context_cleanup_do_not_touch_reaped_queue(harness: Harness) -> None:
    """Manual shutdown and context cleanup share one cleanup attempt."""
    with harness.manager:
        harness.manager.shutdown()
        harness.manager.shutdown()

    harness.manager.shutdown()

    assert harness.process.method_calls == [call.shutdown()]
    assert harness.display.method_calls == [call.close()]


def test_shutdown_rejects_operations_before_terminating_process(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """All operation guards take effect before process cleanup can fail or interrupt."""
    deck, config = valid_inputs
    path_validation = Mock(return_value=False)
    config_validation = Mock()
    monkeypatch.setattr(Path, "is_file", path_validation)
    monkeypatch.setattr(SimulationConfig, "validate", config_validation)

    def on_shutdown() -> None:
        with pytest.raises(RuntimeError, match="shutdown"):
            harness.manager.add(deck, config)
        with pytest.raises(RuntimeError, match="shutdown"):
            harness.manager.__enter__()
        with pytest.raises(RuntimeError, match="shutdown"):
            harness.manager.wait()
        with pytest.raises(RuntimeError, match="shutdown"):
            _ = list(harness.manager.follow())

    harness.process.shutdown.side_effect = on_shutdown
    harness.manager.shutdown()

    path_validation.assert_not_called()
    config_validation.assert_not_called()
    assert harness.process.method_calls == [call.shutdown()]


@pytest.mark.parametrize(
    ("failure_point", "error_type"),
    [
        ("clean", None),
        ("process", OSError),
        ("process", KeyboardInterrupt),
        ("display", RuntimeError),
        ("display", KeyboardInterrupt),
    ],
)
def test_shutdown_is_one_shot_and_rejects_operations_even_after_failure(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    failure_point: str,
    error_type: type[BaseException] | None,
) -> None:
    """Closure is permanent and later cleanup does nothing, regardless of failure."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1")]
    simulation = harness.manager.add(deck, config)
    harness.process.reset_mock()

    def assert_operations_rejected() -> None:
        for path in (deck, deck.with_name("missing.dck")):
            with pytest.raises(RuntimeError, match="shutdown"):
                harness.manager.add(path, config)
        with pytest.raises(RuntimeError, match="shutdown"):
            harness.manager.__enter__()
        for target in (None, simulation):
            with pytest.raises(RuntimeError, match="shutdown"):
                harness.manager.wait(target)
            with pytest.raises(RuntimeError, match="shutdown"):
                _ = list(harness.manager.follow(target))

    harness.display.reset_mock()
    lifecycle = Mock()
    lifecycle.attach_mock(harness.process.shutdown, "shutdown_process")
    lifecycle.attach_mock(harness.display.close, "close_display")
    shutdown_error = error_type("shutdown interrupted") if error_type is not None else None
    if failure_point == "process":
        harness.process.shutdown.side_effect = shutdown_error
    elif failure_point == "display":
        harness.display.close.side_effect = shutdown_error

    with harness.manager:
        if error_type is None:
            harness.manager.shutdown()
        else:
            with pytest.raises(error_type) as raised:
                harness.manager.shutdown()
            assert raised.value is shutdown_error
        harness.manager.shutdown()
    harness.manager.shutdown()
    assert_operations_rejected()

    assert lifecycle.method_calls == [call.shutdown_process(), call.close_display()]
    harness.process.read_line.assert_not_called()
    harness.process.send.assert_not_called()
    assert harness.manager.simulations == [simulation]
    assert not simulation.is_finished
    assert harness.manager.succeeded == []
    assert harness.manager.failed == []


def test_shutdown_does_not_accept_interrupted_submissions(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Cleanup does not read pending acceptance or turn unaccepted runs into results."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = OSError("acceptance interrupted")
    with pytest.raises(OSError, match="acceptance interrupted"):
        harness.manager.add(deck, config)
    simulation = harness.manager._active["1"]
    harness.process.reset_mock()
    harness.process.read_line.side_effect = [accepted("1"), completed("1"), None]

    harness.manager.shutdown()

    assert not simulation.is_accepted
    assert not simulation.is_finished
    assert harness.manager.simulations == []
    assert harness.process.method_calls == [call.shutdown()]
    assert harness.display.method_calls == [call.close()]


@pytest.mark.parametrize("targeted", [False, True])
def test_paused_follow_rejects_resume_after_shutdown_with_unfinished_runs(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    *,
    targeted: bool,
) -> None:
    """An iterator already past its entry check cannot read again after shutdown."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), stream("1", "STATUS", status="RUNNING")]
    simulation = harness.manager.add(deck, config)
    updates = harness.manager.follow(simulation if targeted else None)
    assert next(updates) is simulation
    harness.process.reset_mock()
    harness.process.read_line.side_effect = [completed("1"), None]

    harness.manager.shutdown()
    with pytest.raises(RuntimeError, match="shutdown"):
        next(updates)

    assert not simulation.is_finished
    assert simulation.status == StatusEvent("RUNNING", TIMESTAMP)
    assert harness.process.method_calls == [call.shutdown()]


@pytest.mark.parametrize("error_type", [RuntimeError, KeyboardInterrupt])
def test_context_cleanup_preserves_body_exception_without_waiting(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    error_type: type[BaseException],
) -> None:
    """An exception or interrupt kills active work without waiting or masking the error."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), completed("1")]
    body_error = error_type("body failed")
    simulation = harness.manager.add(deck, config)
    harness.process.reset_mock()

    with pytest.raises(error_type) as raised, harness.manager:
        raise body_error

    assert raised.value is body_error
    assert not simulation.is_finished
    assert harness.process.method_calls == [call.shutdown()]
    harness.display.close.assert_called_once_with()


def test_context_cleanup_after_display_error_stops_without_more_callbacks(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A display failure escapes while cleanup still kills the queue and closes display."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), completed("1")]
    display_error = RuntimeError("display failed")
    harness.display.simulation_started.side_effect = display_error

    with pytest.raises(RuntimeError) as raised, harness.manager:
        harness.manager.add(deck, config)

    assert raised.value is display_error
    assert not harness.manager.simulations[0].is_finished
    assert harness.process.read_line.call_count == 1
    harness.process.shutdown.assert_called_once_with()
    harness.display.close.assert_called_once_with()
    harness.display.simulation_finished.assert_not_called()


def test_context_manager_returns_itself_and_shuts_down(harness: Harness) -> None:
    """Leaving an idle manager context closes resources without reading queue output."""
    with harness.manager as entered:
        assert entered is harness.manager

    assert harness.process.method_calls == [call.shutdown()]
    harness.display.close.assert_called_once_with()


def test_context_exit_without_wait_leaves_simulation_unfinished(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A normal context exit does not implicitly finish accepted work."""
    deck, config = valid_inputs
    harness.process.read_line.side_effect = [accepted("1"), completed("1")]

    with harness.manager:
        simulation = harness.manager.add(deck, config)
        harness.process.reset_mock()

    assert not simulation.is_finished
    assert harness.process.method_calls == [call.shutdown()]
    harness.display.close.assert_called_once_with()
