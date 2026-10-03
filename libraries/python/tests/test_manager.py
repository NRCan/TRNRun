# Copyright (c) 2026 His Majesty the King in Right of Canada, as represented by the Minister of Natural Resources.
# ruff: noqa: S101

from __future__ import annotations

import json
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from inspect import signature
from pathlib import Path
from queue import Queue
from threading import Condition, Event, Thread, current_thread
from typing import override
from unittest.mock import Mock, call

import pytest

import trnrun.manager as manager_module
from trnrun.config import SimulationConfig
from trnrun.display import DisplayCallback
from trnrun.events import SimulationStatus, StatusEvent
from trnrun.manager import SimulationManager
from trnrun.process import QueueProcess
from trnrun.simulation import Simulation

TIMESTAMP = "2026-01-02T03:04:05Z"
TEST_TIMEOUT = 10.0


class Worker[T](Thread):
    """Retain results and exceptions, and bound every join in the test thread."""

    def __init__(self, action: Callable[[], T]) -> None:
        """Prepare a tracked worker without starting it."""
        super().__init__(daemon=True)
        self.action: Callable[[], T] = action
        self.values: list[T] = []
        self.error: BaseException | None = None
        self.done: Event = Event()
        self.waits: Queue[None] = Queue()

    @override
    def run(self) -> None:
        """Capture the outcome for assertions in the test thread."""
        try:
            self.values.append(self.action())
        except BaseException as error:  # noqa: BLE001 - report in the pytest thread
            self.error = error
        finally:
            self.done.set()

    def blocked(self) -> None:
        """Wait for entry into a manager condition wait, not merely thread startup."""
        self.waits.get(timeout=TEST_TIMEOUT)
        assert not self.done.is_set(), "operation returned instead of blocking"

    def finish(self) -> None:
        """Fail rather than leaving pytest hung on a deadlocked manager."""
        self.join(TEST_TIMEOUT)
        assert not self.is_alive(), "manager operation deadlocked"

    def result(self) -> T:
        """Return the result or re-raise the worker's original exception."""
        self.finish()
        if self.error is not None:
            raise self.error
        return self.values[0]

    def raises(self, expected: type[Exception]) -> Exception:
        """Assert the worker failed with the expected exception type."""
        self.finish()
        assert isinstance(self.error, expected), repr(self.error)
        return self.error


@dataclass
class Harness:
    """A manager with captured process callbacks and controlled worker lifetimes."""

    manager: SimulationManager
    process: Mock
    display: Mock
    queue_factory: Mock
    display_factory: Mock
    output: Callable[[str], None]
    exit_reader: Callable[[], None]

    workers: list[Thread] = field(default_factory=list)
    gates: list[Event] = field(default_factory=list)

    def start[T](self, action: Callable[[], T]) -> Worker[T]:
        """Start a bounded operation whose lifetime belongs to this fixture."""
        worker = Worker(action)
        self.workers.append(worker)
        worker.start()
        return worker

    def gate(self) -> Event:
        """Make a gate which teardown releases even after an assertion fails."""
        gate = Event()
        self.gates.append(gate)
        return gate

    def add(self, inputs: tuple[Path, SimulationConfig]) -> Simulation:
        """Bound even submissions expected to accept synchronously."""
        return self.start(lambda: self.manager.add(*inputs)).result()

    def emit(self, *lines: str) -> None:
        """Deliver an ordered batch on a reader-like thread, without foreground pumping."""

        def deliver() -> None:
            for line in lines:
                self.output(line)

        self.start(deliver).result()


@pytest.fixture
def make_harness(monkeypatch: pytest.MonkeyPatch) -> Iterator[Callable[..., Harness]]:
    """Capture callbacks rather than providing a synchronous read_line fake."""
    harnesses: list[Harness] = []

    def create(*, injected: bool = True) -> Harness:
        process = Mock(spec=QueueProcess)
        shown = Mock(spec=DisplayCallback)
        display_factory = Mock(return_value=shown)
        callbacks: list[tuple[Callable[[str], None], Callable[[], None]]] = []

        def queue_factory(
            executable: str | Path,
            max_concurrent: int,
            on_output: Callable[[str], None],
            on_exit: Callable[[], None],
        ) -> Mock:
            del executable, max_concurrent
            callbacks.append((on_output, on_exit))
            return process

        factory = Mock(side_effect=queue_factory)
        monkeypatch.setattr(manager_module, "QueueProcess", factory)
        monkeypatch.setattr(manager_module, "create_display", display_factory)
        options = {"display": shown if injected else None}
        manager = SimulationManager(
            max_concurrent=3,
            refresh_interval=0.25,
            trnrunq_path="mock-queue.exe",
            **options,
        )
        ((output, exit_reader),) = callbacks
        harness = Harness(manager, process, shown, factory, display_factory, output, exit_reader)
        harnesses.append(harness)

        def accept_immediately(request: dict[str, object]) -> None:
            run_id = request["runId"]
            assert isinstance(run_id, str)
            output(accepted(run_id))

        process.send.side_effect = accept_immediately

        # Observe real wait boundaries while the manager still owns its lock.
        # Do not depend on its private condition's name, or instrument Event gates.
        conditions = [value for value in vars(manager).values() if isinstance(value, Condition)]
        assert conditions, "the background manager must use a condition to coordinate waiters"
        for condition in conditions:
            original_wait = condition.wait

            def observe_wait(
                timeout: float | None = None,
                *,
                wait: Callable[[float | None], bool] = original_wait,
            ) -> bool:
                worker = current_thread()
                if isinstance(worker, Worker):
                    worker.waits.put(None)
                return wait(timeout)

            monkeypatch.setattr(condition, "wait", observe_wait)
        return harness

    yield create

    for harness in reversed(harnesses):
        for gate in harness.gates:
            gate.set()
        # Cleanup must also be bounded if the implementation regresses.
        harness.process.shutdown.side_effect = None
        cleanup = harness.start(harness.manager.shutdown)
        cleanup.result()
        for worker in harness.workers:
            worker.join(TEST_TIMEOUT)
            assert not worker.is_alive(), "test left a manager worker running"


@pytest.fixture
def harness(make_harness: Callable[..., Harness]) -> Harness:
    """Build a manager using an injected mock display."""
    return make_harness()


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
    return json.dumps({"runId": run_id, "kind": kind, "timestamp": TIMESTAMP, **payload})


def accepted(run_id: str) -> str:
    """Encode queue acceptance for a submitted run."""
    return stream(run_id, "QUEUE", event="ACCEPTED")


def completed(run_id: str, exit_code: int | None = 0) -> str:
    """Encode queue completion without synthesizing a runner status."""
    return stream(run_id, "QUEUE", event="COMPLETED", exitCode=exit_code)


def progress(run_id: str, percent: float) -> str:
    """Encode a valid runner progress update."""
    return stream(run_id, "PROGRESS", time=percent * 10, percent=percent, elapsedMs=1000, etaMs=1000)


def test_constructor_captures_output_callback_and_injects_display(harness: Harness) -> None:
    """Construction connects only the output callback and honors display injection."""
    harness.queue_factory.assert_called_once()
    args, kwargs = harness.queue_factory.call_args
    assert signature(QueueProcess).bind(*args, **kwargs).arguments == {
        "executable": "mock-queue.exe",
        "max_concurrent": 3,
        "on_output": harness.output,
        "on_exit": harness.exit_reader,
    }
    assert callable(harness.output)

    harness.display_factory.assert_not_called()
    assert harness.manager.submitted == []
    assert harness.manager.simulations == []
    assert harness.manager.active == []
    assert harness.manager.succeeded == []
    assert harness.manager.failed == []


def test_display_none_selects_automatic_display(make_harness: Callable[..., Harness]) -> None:
    """A missing display delegates selection and refresh timing to the factory."""
    harness = make_harness(injected=False)
    harness.display_factory.assert_called_once_with(0.25)
    harness.start(harness.manager.shutdown).result()
    harness.display.close.assert_called_once_with()


def test_startup_failure_propagates(monkeypatch: pytest.MonkeyPatch) -> None:
    """A queue startup error propagates to the caller."""
    startup_error = OSError("queue startup failed")
    display = Mock(spec=DisplayCallback)
    factory = Mock(side_effect=startup_error)
    monkeypatch.setattr(manager_module, "QueueProcess", factory)

    with pytest.raises(OSError, match="queue startup failed") as raised:
        SimulationManager(max_concurrent=3, trnrunq_path="mock-queue.exe", display=display)

    assert raised.value is startup_error
    factory.assert_called_once()


def test_add_registers_before_immediate_acceptance_and_copies_config(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Immediate acceptance finds an active handle before it appears in simulations."""
    deck, config = valid_inputs
    registered: list[Simulation] = []

    def send(request: dict[str, object]) -> None:
        run_id = request["runId"]
        assert isinstance(run_id, str)
        assert harness.manager.simulations == []
        (simulation,) = harness.manager.active
        assert simulation.id == int(run_id)
        assert not simulation.is_accepted
        registered.append(simulation)
        harness.output(accepted(str(simulation.id)))

    harness.process.send.side_effect = send
    simulation = harness.add(valid_inputs)

    assert registered == [simulation]
    assert simulation.id == 1
    assert simulation.deck_path == deck.absolute()
    assert simulation.config == config
    assert simulation.config is not config
    assert simulation.snapshot().is_accepted
    assert harness.manager.simulations == [simulation]
    assert harness.manager.active == [simulation]
    active = harness.manager.active
    active.clear()
    assert harness.manager.active == [simulation]
    harness.process.send.assert_called_once_with(
        {
            "runId": "1",
            "deckFile": str(deck.absolute()),
            "runnerPath": str(simulation.config.trnrun_path),
            "runnerArgs": simulation.config.to_cli_args(),
        },
    )
    harness.display.simulation_started.assert_called_once_with(simulation)


def test_completion_before_add_resumes_returns_the_finished_handle(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Acceptance and completion can both arrive while the submission is still sending."""
    sending = Event()
    release = harness.gate()

    def send(request: dict[str, object]) -> None:
        assert request["runId"] == "1"
        sending.set()
        assert release.wait(TEST_TIMEOUT)

    harness.process.send.side_effect = send
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    assert sending.wait(TEST_TIMEOUT)
    assert harness.manager.simulations == []
    (simulation,) = harness.manager.active
    harness.emit(accepted("1"), stream("1", "STATUS", status="DONE"), completed("1"))

    assert not submission.done.is_set()
    assert simulation.succeeded
    assert harness.manager.simulations == [simulation]
    assert harness.manager.active == []
    assert harness.manager.succeeded == [simulation]
    before = simulation.snapshot()
    release.set()
    assert submission.result() is simulation
    assert simulation.snapshot() == before
    assert harness.start(lambda: harness.manager.wait(simulation)).result() is None

    harness.display.simulation_started.assert_called_once_with(simulation)
    harness.display.simulation_finished.assert_called_once_with(simulation)


def test_concurrent_submissions_keep_submission_order_and_distinct_ids(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Submission registration must not serialize all callers behind acceptance."""
    harness.process.send.side_effect = None
    first_add = harness.start(lambda: harness.manager.add(*valid_inputs))
    first_add.blocked()
    second_add = harness.start(lambda: harness.manager.add(*valid_inputs))
    second_add.blocked()
    assert harness.manager.simulations == []
    first, second = harness.manager.active
    assert (first.id, second.id) == (1, 2)
    assert first is not second
    harness.emit(accepted("2"))
    assert second_add.result() is second
    assert harness.manager.simulations == [second]
    first_add.blocked()
    harness.emit(accepted("1"))
    assert first_add.result() is first
    assert harness.manager.simulations == [first, second]
    harness.emit(stream("1", "STATUS", status="DONE"), completed("1"))
    harness.emit(stream("2", "STATUS", status="DONE"), completed("2"))
    assert harness.manager.succeeded == [first, second]


def test_add_blocks_for_acceptance_but_callbacks_route_without_foreground_pumping(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Callbacks update pending and accepted runs without a foreground consumer."""
    harness.process.send.side_effect = None
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    submission.blocked()
    assert harness.manager.simulations == []
    (simulation,) = harness.manager.active
    assert simulation.id == 1
    assert not simulation.is_accepted

    harness.emit(stream("1", "STATUS", status="RUNNING", message="launched"))
    submission.blocked()
    assert not submission.done.is_set()
    assert simulation.status_event == StatusEvent(SimulationStatus.RUNNING, TIMESTAMP, "launched")

    harness.emit(accepted("1"))
    assert submission.result() is simulation
    harness.emit(progress("1", 0.5), stream("1", "STATUS", status="DONE"), completed("1", 9))
    snapshot = simulation.snapshot()
    assert snapshot.progress is not None
    assert snapshot.progress.percent == 0.5
    assert snapshot.succeeded
    assert simulation.completion_event is not None
    assert simulation.completion_event.exit_code == 9
    assert harness.manager.active == []
    assert harness.manager.succeeded == [simulation]
    harness.display.simulation_finished.assert_called_once_with(simulation)
    # QueueProcess has no read_line API; all manager activity uses only send/shutdown.
    assert [entry[0] for entry in harness.process.method_calls] == ["send"]


def test_submitted_includes_all_states_in_submission_order(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """GUI observers can discover every handle before and after acceptance."""
    harness.process.send.side_effect = None
    first, second, third = [
        harness.start(lambda: harness.manager.add(*valid_inputs, blocking=False)).result()
        for _ in range(3)
    ]
    handles = harness.manager.submitted
    assert handles == [first, second, third]
    assert harness.manager.simulations == []

    harness.emit(
        accepted("3"),
        stream("3", "STATUS", status="DONE"),
        completed("3"),
        accepted("2"),
        stream("2", "STATUS", status="RUNNING"),
    )
    assert not first.is_accepted
    assert second.status is SimulationStatus.RUNNING
    assert third.succeeded
    assert harness.manager.submitted == [first, second, third]
    assert harness.manager.simulations == [second, third]
    assert harness.manager.active == [first, second]
    assert handles[2].succeeded

    handles.clear()
    assert harness.manager.submitted == [first, second, third]
    harness.start(harness.manager.shutdown).result()
    assert harness.manager.submitted == [first, second, third]


def test_nonblocking_add_returns_pending_handle_and_waits_for_completion(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A submitted handle can be waited on before a worker accepts it."""
    harness.process.send.side_effect = None
    simulation = harness.start(lambda: harness.manager.add(*valid_inputs, blocking=False)).result()
    assert not simulation.is_accepted
    assert harness.manager.active == [simulation]
    assert harness.manager.simulations == []

    waiting = harness.start(lambda: harness.manager.wait(simulation))
    waiting.blocked()
    harness.emit(accepted("1"))
    waiting.blocked()
    assert harness.manager.simulations == [simulation]
    harness.emit(completed("1"))
    assert waiting.result() is None
    assert simulation.is_finished
    assert harness.manager.active == []


def test_noise_malformed_unknown_and_duplicate_events_are_ignored(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Invalid or redundant lines leave state and display unchanged without stopping routing."""
    simulation = harness.add(valid_inputs)
    harness.display.reset_mock()
    before = simulation.snapshot()
    harness.emit(
        "native diagnostic output\n",
        "{not json",
        stream("1", "STATUS"),
        stream("1", "STATUS", status="FUTURE"),
        accepted("999"),
        completed("999"),
        stream("1", "QUEUE", event="ENQUEUED"),
        accepted("1"),
    )
    assert simulation.snapshot() == before
    assert harness.manager.simulations == [simulation]
    assert harness.display.method_calls == []

    harness.emit(progress("1", 0.25))
    assert simulation.progress is not None
    assert simulation.progress.percent == 0.25
    harness.display.refresh.assert_called_once_with()


def test_background_completion_counters_and_result_lists_are_live_handles(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Callbacks maintain counters and ordered results while snapshots stay immutable."""
    first, second, third = [harness.add(valid_inputs) for _ in range(3)]
    frozen = first.snapshot()
    harness.emit(
        stream("1", "LOG", severity="Notice", message="notice"),
        stream("1", "LOG", severity="Warning", message="warning"),
        stream("1", "LOG", severity="Fatal", message="fatal"),
        stream("2", "STATUS", status="ERROR"),
        completed("2"),
        completed("3", None),
        stream("1", "STATUS", status="DONE"),
    )
    assert harness.manager.active == [first]
    assert not first.succeeded  # Runner DONE does not replace QUEUE/COMPLETED.
    harness.emit(completed("1", 17))
    assert harness.manager.simulations == [first, second, third]
    assert harness.manager.succeeded == [first]
    assert harness.manager.failed == [second, third]
    assert harness.manager.active == []
    snapshot = first.snapshot()
    assert (snapshot.log_count, snapshot.notices, snapshot.warnings, snapshot.fatals) == (3, 1, 1, 1)
    assert frozen.log_count == 0
    assert not frozen.is_finished
    for name in ("submitted", "simulations", "active", "succeeded", "failed"):
        result = getattr(harness.manager, name)
        assert isinstance(result, list)
        expected = result.copy()
        result.clear()
        assert getattr(harness.manager, name) == expected

    harness.display.simulation_started.assert_has_calls([call(first), call(second), call(third)])
    harness.display.simulation_finished.assert_has_calls([call(second), call(third), call(first)])
    harness.display.reset_mock()
    harness.emit(completed("1"), progress("1", 0.99), accepted("1"))
    assert first.snapshot() == snapshot
    assert harness.display.method_calls == []


def test_add_rejects_invalid_paths_before_sending(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    tmp_path: Path,
) -> None:
    """Invalid deck or runner paths fail before registration and process submission."""
    deck, config = valid_inputs
    with pytest.raises(FileNotFoundError, match="Deck file not found"):
        harness.add((tmp_path / "missing.dck", config))
    invalid = SimulationConfig(trnrun_path=tmp_path / "missing.exe", trnexe_path=config.trnexe_path)
    with pytest.raises(FileNotFoundError, match="TRNRun executable not found"):
        harness.add((deck, invalid))
    harness.process.send.assert_not_called()
    assert harness.manager.simulations == []
    assert harness.manager.active == []


def test_ownership_uses_identity_even_when_ids_match(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Wait rejects foreign handles even if their IDs match an owned run."""
    owned = harness.add(valid_inputs)
    outsider = Simulation(*valid_inputs, sim_id=owned.id)
    harness.start(lambda: harness.manager.wait(outsider)).raises(ValueError)
    assert harness.manager.simulations == [owned]


def test_wait_targets_only_selected_run(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Waiting for one run does not depend on other runs completing."""
    first, second = [harness.add(valid_inputs) for _ in range(2)]
    targeted = harness.start(lambda: harness.manager.wait(first))
    all_runs = harness.start(harness.manager.wait)
    targeted.blocked()
    all_runs.blocked()
    harness.emit(progress("2", 0.2))
    targeted.blocked()
    all_runs.blocked()
    harness.emit(completed("1"))
    assert targeted.result() is None
    all_runs.blocked()
    assert not second.is_finished
    assert harness.start(lambda: harness.manager.wait(first)).result() is None
    harness.emit(completed("2"))
    assert all_runs.result() is None


def test_all_waits_include_submitted_but_unaccepted_runs(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Waiting for all includes a submission still awaiting acceptance."""
    harness.process.send.side_effect = None
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    submission.blocked()
    waiting = harness.start(harness.manager.wait)
    waiting.blocked()
    harness.emit(accepted("1"))
    submission.result()
    waiting.blocked()
    harness.emit(completed("1"))
    assert waiting.result() is None


def test_completed_target_succeeds_despite_unrelated_unfinished_runs(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A completed target returns while all-run observers still wait for other runs."""
    first, second = [harness.add(valid_inputs) for _ in range(2)]
    harness.emit(completed("1"))
    assert harness.start(lambda: harness.manager.wait(first)).result() is None
    pending = harness.start(harness.manager.wait)
    pending.blocked()
    assert not second.is_finished
    harness.emit(completed("2"))
    assert pending.result() is None


def test_no_outstanding_runs_returns_from_wait(harness: Harness) -> None:
    """An empty completion scope returns without waiting for output."""
    assert harness.start(harness.manager.wait).result() is None


@pytest.mark.parametrize("accept_before_error", [False, True])
@pytest.mark.parametrize("blocking", [False, True])
def test_send_failure_rolls_back_only_unaccepted_runs(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    *,
    accept_before_error: bool,
    blocking: bool,
) -> None:
    """Send failures remove pending registrations but preserve accepted live runs."""
    failure = OSError("send failed")
    registered: list[Simulation] = []

    def send(request: dict[str, object]) -> None:
        run_id = request["runId"]
        assert isinstance(run_id, str)
        assert harness.manager.simulations == []
        (simulation,) = harness.manager.active
        assert simulation.id == int(run_id)
        registered.append(simulation)
        assert harness.manager.submitted == [simulation]
        if accept_before_error:
            harness.output(accepted(str(request["runId"])))
        raise failure

    harness.process.send.side_effect = send
    assert harness.start(lambda: harness.manager.add(*valid_inputs, blocking=blocking)).raises(OSError) is failure
    simulation = registered[0]
    assert harness.manager.submitted == ([simulation] if accept_before_error else [])
    if accept_before_error:
        assert harness.manager.simulations == [simulation]
        assert harness.manager.active == [simulation]
        harness.emit(stream("1", "STATUS", status="DONE"), completed("1"))
        assert harness.manager.succeeded == [simulation]
    else:
        assert harness.manager.simulations == []
        assert harness.manager.active == []
        harness.emit(accepted("1"), completed("1"))
        assert harness.manager.simulations == []
        harness.display.simulation_started.assert_not_called()


def test_send_rollback_notifies_all_waiters(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Removing the last pending submission wakes every completion observer."""
    sending = Event()
    release = harness.gate()
    failure = OSError("send rolled back")

    def send(request: dict[str, object]) -> None:
        del request
        sending.set()
        assert release.wait(TEST_TIMEOUT)
        raise failure

    harness.process.send.side_effect = send
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    assert sending.wait(TEST_TIMEOUT)
    waits = [harness.start(harness.manager.wait) for _ in range(2)]
    for worker in waits:
        worker.blocked()
    release.set()
    assert submission.raises(OSError) is failure
    for worker in waits:
        assert worker.result() is None

    assert harness.manager.active == []
    assert harness.manager.simulations == []


def test_reader_exit_wakes_only_unfinished_work(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Unexpected stdout EOF must not leave acceptance or completion waiters blocked."""
    finished = harness.add(valid_inputs)
    harness.emit(completed("1"))
    harness.process.send.side_effect = None
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    submission.blocked()
    waiting = harness.start(harness.manager.wait)
    waiting.blocked()

    harness.exit_reader()

    assert "before acceptance" in str(submission.raises(RuntimeError))
    assert "before completion" in str(waiting.raises(RuntimeError))
    assert harness.start(lambda: harness.manager.wait(finished)).result() is None
    harness.start(lambda: harness.manager.add(*valid_inputs, blocking=False)).raises(RuntimeError)
    assert harness.manager.active[0].id == 2


def test_shutdown_wakes_waiting_add_and_wait_and_ignores_late_output(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Shutdown releases all blocked callers and prevents late output from changing state."""
    accepted_simulation = harness.add(valid_inputs)
    harness.process.send.side_effect = None
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    submission.blocked()
    assert harness.manager.simulations == [accepted_simulation]
    unfinished = next(simulation for simulation in harness.manager.active if simulation.id == 2)
    snapshots = [simulation.snapshot() for simulation in (accepted_simulation, unfinished)]
    waits = [harness.start(harness.manager.wait) for _ in range(2)]
    for worker in waits:
        worker.blocked()
    harness.display.reset_mock()
    harness.start(harness.manager.shutdown).result()
    for worker in [submission, *waits]:
        worker.raises(RuntimeError)
    harness.emit(accepted("2"), stream("1", "STATUS", status="DONE"), completed("1"), completed("2"))
    assert [simulation.snapshot() for simulation in (accepted_simulation, unfinished)] == snapshots
    assert harness.manager.succeeded == []
    assert harness.manager.failed == []
    assert harness.display.method_calls == [call.close()]
    harness.start(harness.manager.shutdown).result()
    harness.process.shutdown.assert_called_once_with()
    harness.display.close.assert_called_once_with()


def test_shutdown_notifies_before_blocking_process_cleanup(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Waiters learn the manager is closed before process cleanup finishes."""
    harness.add(valid_inputs)
    pending = harness.start(harness.manager.wait)
    pending.blocked()
    cleaning = Event()
    release = harness.gate()

    def shutdown() -> None:
        cleaning.set()
        assert release.wait(TEST_TIMEOUT)

    harness.process.shutdown.side_effect = shutdown
    closing = harness.start(harness.manager.shutdown)
    assert cleaning.wait(TEST_TIMEOUT)
    pending.raises(RuntimeError)
    assert not closing.done.is_set()
    release.set()
    closing.result()


def test_shutdown_retries_queue_cleanup_after_failure(harness: Harness) -> None:
    """A failed cleanup keeps work closed but allows a later shutdown to finish."""
    failure = TimeoutError("queue reader did not exit")
    harness.process.shutdown.side_effect = failure
    assert harness.start(harness.manager.shutdown).raises(TimeoutError) is failure
    harness.display.close.assert_not_called()
    harness.start(harness.manager.__enter__).raises(RuntimeError)
    harness.start(harness.manager.wait).raises(RuntimeError)

    harness.process.shutdown.side_effect = None
    harness.start(harness.manager.shutdown).result()
    assert harness.process.shutdown.call_count == 2
    harness.display.close.assert_called_once_with()
    harness.start(harness.manager.shutdown).result()
    assert harness.process.shutdown.call_count == 2
    harness.display.close.assert_called_once_with()


def test_shutdown_retries_display_close_after_failure(harness: Harness) -> None:
    """A display close error also leaves shutdown retryable."""
    failure = OSError("display close failed")
    harness.display.close.side_effect = failure
    assert harness.start(harness.manager.shutdown).raises(OSError) is failure
    harness.process.shutdown.assert_called_once_with()

    harness.display.close.side_effect = None
    harness.start(harness.manager.shutdown).result()
    assert harness.process.shutdown.call_count == 2
    assert harness.display.close.call_count == 2
    harness.start(harness.manager.shutdown).result()
    assert harness.process.shutdown.call_count == 2
    assert harness.display.close.call_count == 2


def test_shutdown_rejects_future_operations(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Closed managers reject new operations."""
    harness.add(valid_inputs)
    harness.start(harness.manager.shutdown).result()
    actions = [
        lambda: harness.manager.add(*valid_inputs),
        harness.manager.wait,
        harness.manager.__enter__,
    ]
    for action in actions:
        harness.start(action).raises(RuntimeError)
    harness.process.send.assert_called_once()


@pytest.mark.parametrize("callback", ["simulation_started", "refresh", "simulation_finished"])
def test_display_failures_are_silent_and_do_not_escape(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    callback: str,
    recwarn: pytest.WarningsRecorder,
) -> None:
    """Display update failures are silent without disrupting simulation results."""
    failure = RuntimeError(f"{callback} display failed")
    getattr(harness.display, callback).side_effect = failure

    def run_with_broken_display() -> Simulation:
        simulation = harness.add(valid_inputs)
        harness.emit(progress("1", 0.5), stream("1", "STATUS", status="DONE"), completed("1"))
        assert harness.start(harness.manager.wait).result() is None
        harness.start(harness.manager.shutdown).result()
        return simulation

    simulation = run_with_broken_display()
    assert not recwarn
    assert simulation.succeeded
    assert harness.manager.succeeded == [simulation]

    harness.display.close.assert_called_once_with()


def test_shutdown_closes_display_only_after_reader_exits(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A callback in progress completes before queue cleanup closes the display."""
    harness.add(valid_inputs)
    entered = Event()
    release = harness.gate()

    def refresh() -> None:
        entered.set()
        assert release.wait(TEST_TIMEOUT)

    harness.display.refresh.side_effect = refresh
    reader = harness.start(lambda: harness.output(progress("1", 0.5)))
    assert entered.wait(TEST_TIMEOUT)

    def shutdown_process() -> None:
        reader.finish()  # QueueProcess.shutdown joins its output reader.

    harness.process.shutdown.side_effect = shutdown_process
    closing = harness.start(harness.manager.shutdown)
    assert not reader.done.is_set()
    harness.display.close.assert_not_called()
    release.set()
    closing.result()
    harness.display.close.assert_called_once_with()


@pytest.mark.parametrize("finish_before_exit", [False, True])
def test_context_manager_preserves_state_without_synthesizing_completion(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    *,
    finish_before_exit: bool,
) -> None:
    """Context exit aborts pending runs but retains already completed results."""
    simulation = harness.add(valid_inputs)
    if finish_before_exit:
        harness.emit(stream("1", "STATUS", status="DONE"), completed("1"))
        assert harness.start(harness.manager.wait).result() is None
    before = simulation.snapshot()

    def use_context() -> None:
        with harness.manager as entered:
            assert entered is harness.manager

    harness.start(use_context).result()
    assert simulation.snapshot() == before
    assert harness.manager.succeeded == ([simulation] if finish_before_exit else [])
    harness.process.shutdown.assert_called_once_with()
    harness.display.close.assert_called_once_with()
