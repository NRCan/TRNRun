# Copyright (c) 2026 His Majesty the King in Right of Canada, as represented by the Minister of Natural Resources.
# ruff: noqa: S101, SLF001

from __future__ import annotations

import threading
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from queue import Queue
from threading import Condition, Event, Lock, Thread, current_thread
from typing import override
from unittest.mock import Mock

import pytest

import trnrun.manager as manager_module
from trnrun.config import SimulationConfig
from trnrun.display import ProgressDisplay
from trnrun.events import LogEvent, SimulationState, SimulationStatus, StatusEvent
from trnrun.manager import SHUTDOWN_REASON, SimulationManager
from trnrun.simulation import Simulation, SimulationSnapshot

TEST_TIMEOUT = 10.0
# The poller only runs when woken by a submission or by `Harness.poll`.
NEVER = 3600.0


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


class FakeDaemon:
    """In-memory daemon following the trnrund request protocol.

    Tests change daemon-side state directly, as TRNRun output and worker
    exits would, then let the manager's poller observe it.
    """

    def __init__(self) -> None:
        self.lock: Lock = Lock()
        self.runs: dict[str, dict[str, object]] = {}
        self.logs: dict[str, list[dict[str, object]]] = {}
        self.requests: list[dict[str, object]] = []
        self.accept_on_add: bool = True
        self.add_error: Exception | None = None
        self.failure: Exception | None = None
        self.shutdown: Mock = Mock()

    def request(self, request: dict[str, object]) -> dict[str, object]:
        """Answer one request like trnrund, raising for ``ok: false``."""
        with self.lock:
            self.requests.append(request)
            if self.failure is not None:
                raise self.failure
            command = request["cmd"]
            run_id = str(request.get("runId"))
            if command == "add":
                if self.add_error is not None:
                    raise self.add_error
                if run_id in self.runs:
                    raise ValueError(f"Invalid or duplicate runId: {run_id}")
                self.runs[run_id] = self._initial(run_id, request)
                self.logs[run_id] = []
                return {"ok": True}
            if command == "snapshots":
                run_ids = request["runIds"]
                assert isinstance(run_ids, list)
                return {"ok": True, "simulations": [dict(self._known(str(item))) for item in run_ids]}
            if command == "logs":
                start, stop = request["start"], request["stop"]
                assert isinstance(start, int)
                assert isinstance(stop, int)
                self._known(run_id)
                return {"ok": True, "logs": list(self.logs[run_id][start:stop])}
            if command == "collect":
                simulation = self._known(run_id)
                if simulation["state"] != "FINISHED":
                    raise ValueError(f"Simulation has not finished: {run_id}")
                del self.runs[run_id]
                return {"ok": True, "simulation": dict(simulation), "logs": self.logs.pop(run_id)}
            raise ValueError(f"Unknown cmd: {command}")

    def set(self, run_id: str, **fields: object) -> None:
        """Change daemon-side fields of a run."""
        with self.lock:
            self.runs[run_id].update(fields)

    def log(self, run_id: str, severity: str = "Notice", message: str = "message") -> None:
        """Append one TRNRun log entry, as the daemon counts it."""
        with self.lock:
            self.logs[run_id].append(
                {
                    "severity": severity,
                    "time": 0.0,
                    "unitId": None,
                    "typeId": None,
                    "messageCode": None,
                    "message": message,
                    "information": None,
                },
            )
            counter = {"Notice": "notices", "Warning": "warnings", "Fatal": "fatals"}[severity]
            simulation = self.runs[run_id]
            simulation[counter] = int(str(simulation[counter])) + 1

    def finish(self, run_id: str, status: str = "DONE", exit_code: int | None = 0, error: str = "") -> None:
        """Finish a run with the daemon's success rule."""
        self.set(
            run_id,
            state="FINISHED",
            status={"status": status, "message": ""},
            exitCode=exit_code,
            error=error,
            succeeded=status == "DONE" and exit_code == 0 and not error,
        )

    def commands(self) -> list[object]:
        """Return the commands received so far."""
        with self.lock:
            return [request["cmd"] for request in self.requests]

    def _initial(self, run_id: str, request: dict[str, object]) -> dict[str, object]:
        return {
            "runId": run_id,
            "deckFile": request["deckFile"],
            "trnrunArgs": request.get("trnrunArgs", []),
            "state": "ACCEPTED" if self.accept_on_add else "QUEUED",
            "exitCode": None,
            "error": "",
            "setting": None,
            "status": None,
            "config": None,
            "progress": None,
            "notices": 0,
            "warnings": 0,
            "fatals": 0,
            "succeeded": False,
        }

    def _known(self, run_id: str) -> dict[str, object]:
        if run_id not in self.runs:
            raise ValueError(f"Unknown runId: {run_id}")
        return self.runs[run_id]


class FakeTracker:
    """Record what the manager hands an attached tracker, and the run states at close."""

    def __init__(self, close_error: Exception | None = None) -> None:
        self.tracked: list[Simulation] = []
        self.closed_with: list[list[SimulationSnapshot]] = []
        self.close_error: Exception | None = close_error

    def track(self, simulation: Simulation) -> None:
        """Record a handed-over run."""
        self.tracked.append(simulation)

    def close(self) -> None:
        """Record every tracked run's state when closed."""
        self.closed_with.append([simulation.snapshot() for simulation in self.tracked])
        if self.close_error is not None:
            raise self.close_error


@dataclass
class Harness:
    """A manager whose real poller is driven against a fake daemon."""

    manager: SimulationManager
    daemon: FakeDaemon
    daemon_factory: Mock
    polls: Condition
    poll_counts: list[int]

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

    def add(self, inputs: tuple[Path, SimulationConfig], *, blocking: bool = True) -> Simulation:
        """Bound even submissions expected to return promptly."""
        return self.start(lambda: self.manager.add(*inputs, blocking=blocking)).result()

    def poll(self) -> None:
        """Wake the poller and wait for a full poll that started after this call."""
        with self.polls:
            target = self.poll_counts[0] + 1
        self.manager._wake.set()
        with self.polls:
            assert self.polls.wait_for(lambda: self.poll_counts[1] >= target, TEST_TIMEOUT), "poller did not run"


@pytest.fixture
def make_harness(monkeypatch: pytest.MonkeyPatch) -> Iterator[Callable[..., Harness]]:
    """Build managers backed by a fake daemon, with bounded teardown."""
    harnesses: list[Harness] = []

    def create(*, poll_interval: float = NEVER) -> Harness:
        daemon = FakeDaemon()
        daemon_factory = Mock(return_value=daemon)
        monkeypatch.setattr(manager_module, "DaemonProcess", daemon_factory)

        # Count poll cycles: [started, finished]. Patched before the poller starts.
        polls = Condition()
        counts = [0, 0]
        original_poll = SimulationManager._poll

        def tracked(self: SimulationManager, simulations: list[Simulation]) -> None:
            with polls:
                counts[0] += 1
                cycle = counts[0]
            try:
                original_poll(self, simulations)
            finally:
                with polls:
                    counts[1] = cycle
                    polls.notify_all()

        monkeypatch.setattr(SimulationManager, "_poll", tracked)
        manager = SimulationManager(
            max_concurrent=3,
            poll_interval=poll_interval,
            trnrun_path="mock-trnrun.exe",
            trnrund_path="mock-daemon.exe",
        )
        harness = Harness(manager, daemon, daemon_factory, polls, counts)
        harnesses.append(harness)

        # Observe real wait boundaries while the manager still owns its lock.
        original_wait = manager._condition.wait

        def observe_wait(timeout: float | None = None) -> bool:
            worker = current_thread()
            if isinstance(worker, Worker):
                worker.waits.put(None)
            return original_wait(timeout)

        monkeypatch.setattr(manager._condition, "wait", observe_wait)
        return harness

    yield create

    for harness in reversed(harnesses):
        for gate in harness.gates:
            gate.set()
        harness.daemon.shutdown.side_effect = None
        harness.start(harness.manager.shutdown).result()
        assert not harness.manager._poller.is_alive()
        for worker in harness.workers:
            worker.join(TEST_TIMEOUT)
            assert not worker.is_alive(), "test left a manager worker running"


@pytest.fixture
def harness(make_harness: Callable[..., Harness]) -> Harness:
    """Build a manager driven against a fake daemon."""
    return make_harness()


@pytest.fixture
def valid_inputs(tmp_path: Path) -> tuple[Path, SimulationConfig]:
    """Create harmless files satisfying submission validation."""
    deck = tmp_path / "model.dck"
    trnexe = tmp_path / "TrnEXE64.exe"
    for path in (deck, trnexe):
        path.write_text("fixture", encoding="utf-8")
    return deck, SimulationConfig(trnexe_path=trnexe, watch_tmp=True)


def test_constructor_starts_daemon_and_poller(harness: Harness) -> None:
    """Construction passes the daemon, runner, and concurrency, and starts polling."""
    harness.daemon_factory.assert_called_once_with("mock-daemon.exe", "mock-trnrun.exe", 3)
    assert harness.manager._poller.is_alive()
    assert harness.manager._poller.daemon
    assert harness.manager.active == []
    assert harness.manager.error is None


def test_startup_failure_propagates(monkeypatch: pytest.MonkeyPatch) -> None:
    """A daemon startup error propagates to the caller."""
    startup_error = OSError("daemon startup failed")
    factory = Mock(side_effect=startup_error)
    monkeypatch.setattr(manager_module, "DaemonProcess", factory)

    with pytest.raises(OSError, match="daemon startup failed") as raised:
        SimulationManager(max_concurrent=3)

    assert raised.value is startup_error
    factory.assert_called_once()


@pytest.mark.parametrize("poll_interval", [0.0, -1.0, float("nan")])
def test_invalid_poll_interval_fails_before_starting_daemon(
    monkeypatch: pytest.MonkeyPatch,
    poll_interval: float,
) -> None:
    """A poll interval must be positive."""
    factory = Mock()
    monkeypatch.setattr(manager_module, "DaemonProcess", factory)

    with pytest.raises(ValueError, match="poll_interval must be positive"):
        SimulationManager(poll_interval=poll_interval)

    factory.assert_not_called()


def test_add_sends_request_and_returns_accepted_copy(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A blocking add returns once a worker accepts the run, with an independent config."""
    deck, config = valid_inputs
    simulation = harness.add(valid_inputs)

    assert simulation.id == 1
    assert simulation.deck_path == deck.absolute()
    assert simulation.config == config
    assert simulation.config is not config
    assert simulation.state is SimulationState.ACCEPTED
    assert harness.daemon.requests[0] == {
        "cmd": "add",
        "runId": "1",
        "deckFile": str(deck.absolute()),
        "trnrunArgs": simulation.config.to_cli_args(),
    }
    assert harness.manager.active == [simulation]
    active = harness.manager.active
    active.clear()
    assert harness.manager.active == [simulation]


def test_daemon_rejection_propagates_without_registering(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A rejected add raises the daemon's error and tracks nothing."""
    harness.daemon.add_error = ValueError("Deck file not found: model.dck")

    error = harness.start(lambda: harness.manager.add(*valid_inputs)).raises(ValueError)

    assert str(error) == "Deck file not found: model.dck"
    assert harness.manager.active == []
    harness.daemon.add_error = None
    assert harness.add(valid_inputs).id == 2


def test_add_rejects_invalid_paths_before_sending(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    tmp_path: Path,
) -> None:
    """Invalid deck or TRNSYS paths fail before registration and submission."""
    deck, config = valid_inputs
    with pytest.raises(FileNotFoundError, match="Deck file not found"):
        harness.add((tmp_path / "missing.dck", config))
    with pytest.raises(FileNotFoundError, match="TrnEXE executable not found"):
        harness.add((deck, SimulationConfig(trnexe_path=tmp_path / "missing.exe")))
    assert harness.daemon.requests == []
    assert harness.manager.active == []


def test_blocking_add_waits_while_queued(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A queued run blocks its submission until a poll observes acceptance."""
    harness.daemon.accept_on_add = False
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    submission.blocked()
    (simulation,) = harness.manager.active
    harness.poll()
    assert not submission.done.is_set()
    assert not simulation.is_accepted

    harness.daemon.set("1", state="RUNNING", status={"status": "RUNNING", "message": "launched"})
    harness.poll()

    assert submission.result() is simulation
    assert simulation.status_event == StatusEvent(SimulationStatus.RUNNING, "launched")


def test_blocking_add_returns_a_run_accepted_and_finished_within_one_poll(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A run that finishes before any poll saw it accepted still releases its submission."""
    harness.daemon.accept_on_add = False
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    submission.blocked()
    harness.daemon.finish("1")
    harness.poll()

    simulation = submission.result()
    assert simulation.succeeded
    assert harness.manager.active == []


def test_nonblocking_add_never_waits_for_a_worker(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Queued runs return at once, can be waited on, and leave the manager once finished."""
    harness.daemon.accept_on_add = False
    first, second, third = [harness.add(valid_inputs, blocking=False) for _ in range(3)]
    harness.poll()
    assert [simulation.state for simulation in (first, second, third)] == [SimulationState.QUEUED] * 3
    assert harness.manager.active == [first, second, third]

    waiting = harness.start(lambda: harness.manager.wait(first))
    waiting.blocked()
    harness.daemon.finish("3")
    harness.daemon.set("2", state="RUNNING", status={"status": "RUNNING", "message": "launched"})
    harness.poll()
    waiting.blocked()
    assert third.succeeded
    assert second.status_event == StatusEvent(SimulationStatus.RUNNING, "launched")
    assert harness.manager.active == [first, second]

    harness.daemon.finish("1")
    harness.poll()
    assert waiting.result() is None
    assert first.is_finished
    assert harness.manager.active == [second]


def test_poll_fetches_only_new_logs_and_skips_unchanged_runs(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Logs are requested from the count already held, and only when the daemon has more."""
    simulation = harness.add(valid_inputs)
    harness.daemon.log("1", "Notice", "one")
    harness.daemon.log("1", "Warning", "two")
    harness.poll()
    assert [event.message for event in simulation.logs] == ["one", "two"]

    harness.daemon.log("1", "Fatal", "three")
    harness.poll()
    harness.poll()

    log_requests = [request for request in harness.daemon.requests if request["cmd"] == "logs"]
    assert log_requests == [
        {"cmd": "logs", "runId": "1", "start": 0, "stop": 2},
        {"cmd": "logs", "runId": "1", "start": 2, "stop": 3},
    ]
    assert simulation.logs == [
        LogEvent("Notice", 0.0, message="one"),
        LogEvent("Warning", 0.0, message="two"),
        LogEvent("Fatal", 0.0, message="three"),
    ]
    assert (simulation.notices, simulation.warnings, simulation.fatals) == (1, 1, 1)


def test_logs_stop_at_the_snapshot_counters(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A log written between the snapshot and the logs request waits for the next poll."""
    simulation = harness.add(valid_inputs)
    harness.daemon.log("1", "Notice", "one")
    request = harness.daemon.request

    def log_after_snapshot(payload: dict[str, object]) -> dict[str, object]:
        reply = request(payload)
        if payload["cmd"] == "snapshots":
            harness.daemon.log("1", "Warning", "late")
        return reply

    monkeypatch.setattr(harness.daemon, "request", log_after_snapshot)
    harness.poll()
    assert [event.message for event in simulation.logs] == ["one"]
    assert (simulation.log_count, simulation.notices, simulation.warnings) == (1, 1, 0)

    monkeypatch.setattr(harness.daemon, "request", request)
    harness.poll()
    assert [event.message for event in simulation.logs] == ["one", "late"]
    assert (simulation.log_count, simulation.notices, simulation.warnings) == (2, 1, 1)


def test_finished_run_is_collected_with_its_final_logs_and_forgotten(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Completion arrives with the remaining logs; the daemon and the manager forget the run."""
    simulation = harness.add(valid_inputs)
    harness.daemon.log("1", "Notice", "early")
    harness.poll()
    harness.daemon.log("1", "Warning", "late")
    harness.daemon.finish("1", exit_code=0)
    harness.poll()

    snapshot = simulation.snapshot()
    assert snapshot.is_finished
    assert snapshot.succeeded
    assert snapshot.exit_code == 0
    assert snapshot.log_count == 2
    assert [event.message for event in simulation.logs] == ["early", "late"]
    assert harness.daemon.runs == {}
    assert harness.daemon.commands().count("collect") == 1
    assert harness.manager.active == []
    assert harness.manager._simulations == {}

    harness.poll()
    assert harness.daemon.commands()[-1] == "collect"  # Nothing is left to poll.


def test_results_follow_the_daemon_verdict(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A DONE status with a failing exit code or daemon error is not a success."""
    done, nonzero, error, unlaunched = [harness.add(valid_inputs) for _ in range(4)]
    harness.daemon.finish("1")
    harness.daemon.finish("2", exit_code=7)
    harness.daemon.finish("3", error="capture failed")
    harness.daemon.finish("4", status="ERROR", exit_code=None, error="launch failed")
    harness.poll()

    assert [simulation.succeeded for simulation in (done, nonzero, error, unlaunched)] == [True, False, False, False]
    assert nonzero.status is SimulationStatus.DONE
    assert (unlaunched.exit_code, unlaunched.error) == (None, "launch failed")
    assert harness.manager.active == []


def test_periodic_polling_without_wakeups(
    make_harness: Callable[..., Harness],
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """The poller also runs on its own interval."""
    harness = make_harness(poll_interval=0.01)
    simulation = harness.add(valid_inputs)
    harness.daemon.finish("1")

    assert harness.start(lambda: harness.manager.wait(simulation)).result() is None
    assert simulation.succeeded


def test_wait_rejects_foreign_unfinished_handles_even_when_ids_match(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Wait uses identity for unfinished runs; any finished handle returns at once."""
    owned = harness.add(valid_inputs)
    outsider = Simulation(*valid_inputs, sim_id=owned.id)
    harness.start(lambda: harness.manager.wait(outsider)).raises(ValueError)

    assert outsider.abandon(SimulationStatus.CANCELLED, "outside")
    assert harness.start(lambda: harness.manager.wait(outsider)).result() is None


def test_wait_targets_only_selected_runs(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Waiting for some runs does not depend on other runs completing."""
    first, second, third = [harness.add(valid_inputs) for _ in range(3)]
    targeted = harness.start(lambda: harness.manager.wait(first, second))
    all_runs = harness.start(harness.manager.wait)
    targeted.blocked()
    all_runs.blocked()
    harness.daemon.finish("1")
    harness.poll()
    targeted.blocked()
    harness.daemon.finish("2")
    harness.poll()
    assert targeted.result() is None
    all_runs.blocked()
    assert not third.is_finished
    harness.daemon.finish("3")
    harness.poll()
    assert all_runs.result() is None


def test_no_outstanding_runs_returns_from_wait(harness: Harness) -> None:
    """An empty completion scope returns without polling."""
    assert harness.start(harness.manager.wait).result() is None


def test_poller_failure_finishes_unfinished_runs_as_errors(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A daemon that dies mid-run finishes every unfinished handle and fails callers loudly."""
    errors: list[threading.ExceptHookArgs] = []
    monkeypatch.setattr(threading, "excepthook", errors.append)
    finished = harness.add(valid_inputs)
    harness.daemon.finish("1")
    harness.poll()
    running = harness.add(valid_inputs)
    harness.daemon.set("2", state="RUNNING", progress={"time": 5, "percent": 0.5, "elapsedMs": 1, "etaMs": 1})
    harness.poll()
    harness.daemon.accept_on_add = False
    submission = harness.start(lambda: harness.manager.add(*valid_inputs))
    submission.blocked()
    waiting = harness.start(harness.manager.wait)
    waiting.blocked()

    failure = RuntimeError("TRNRun daemon exited with code 1")
    harness.daemon.failure = failure
    harness.manager._wake.set()

    for worker in (submission, waiting):
        assert worker.raises(RuntimeError).__cause__ is failure
    harness.manager._poller.join(TEST_TIMEOUT)
    assert [args.exc_value for args in errors] == [failure]
    assert harness.manager.error is failure
    assert harness.manager.active == []

    snapshot = running.snapshot()
    assert snapshot.is_finished
    assert not snapshot.succeeded
    assert snapshot.status is SimulationStatus.ERROR
    assert snapshot.error == "TRNRun daemon polling stopped: TRNRun daemon exited with code 1"
    assert snapshot.progress is not None
    assert finished.succeeded

    harness.start(lambda: harness.manager.wait(finished)).raises(RuntimeError)
    harness.start(lambda: harness.manager.add(*valid_inputs)).raises(RuntimeError)


def test_add_completing_after_polling_stopped_is_not_registered(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A run nothing could ever finish is refused instead of returned."""
    monkeypatch.setattr(threading, "excepthook", lambda _args: None)
    request = harness.daemon.request

    def stop_polling_during_add(payload: dict[str, object]) -> dict[str, object]:
        reply = request(payload)
        if payload["cmd"] == "add":
            harness.manager._stop_polling()
        return reply

    monkeypatch.setattr(harness.daemon, "request", stop_polling_during_add)

    harness.start(lambda: harness.manager.add(*valid_inputs)).raises(RuntimeError)
    assert harness.manager.active == []


def test_shutdown_cancels_unfinished_runs_and_wakes_waiters(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Shutdown releases blocked callers and finishes every unfinished handle as CANCELLED."""
    finished = harness.add(valid_inputs)
    harness.daemon.finish("1")
    harness.poll()
    finished_before = finished.snapshot()
    accepted = harness.add(valid_inputs)
    harness.daemon.accept_on_add = False
    queued = harness.add(valid_inputs, blocking=False)
    harness.poll()
    waits = [
        harness.start(harness.manager.wait),
        harness.start(lambda: harness.manager.wait(queued)),
        harness.start(lambda: harness.manager.add(*valid_inputs)),
    ]
    for worker in waits:
        worker.blocked()

    harness.start(harness.manager.shutdown).result()

    for worker in waits:
        worker.raises(RuntimeError)
    for simulation in (accepted, queued):
        snapshot = simulation.snapshot()
        assert snapshot.is_finished
        assert not snapshot.succeeded
        assert snapshot.status is SimulationStatus.CANCELLED
        assert snapshot.error == SHUTDOWN_REASON
    assert finished.snapshot() == finished_before
    assert harness.manager.active == []

    harness.daemon.finish("2")
    assert accepted.status is SimulationStatus.CANCELLED
    assert not harness.manager._poller.is_alive()
    harness.start(harness.manager.shutdown).result()
    harness.daemon.shutdown.assert_called_once_with()


def test_shutdown_notifies_before_blocking_process_cleanup(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Waiters learn the manager is closed before daemon cleanup finishes."""
    harness.add(valid_inputs)
    pending = harness.start(harness.manager.wait)
    pending.blocked()
    cleaning = Event()
    release = harness.gate()

    def shutdown() -> None:
        cleaning.set()
        assert release.wait(TEST_TIMEOUT)

    harness.daemon.shutdown.side_effect = shutdown
    closing = harness.start(harness.manager.shutdown)
    assert cleaning.wait(TEST_TIMEOUT)
    pending.raises(RuntimeError)
    assert not closing.done.is_set()
    release.set()
    closing.result()


def test_shutdown_retries_daemon_cleanup_after_failure(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """A failed cleanup keeps work closed but allows a later shutdown to finish."""
    simulation = harness.add(valid_inputs)
    tracker = FakeTracker()
    harness.manager._attach(tracker)
    failure = TimeoutError("daemon did not exit")
    harness.daemon.shutdown.side_effect = failure
    assert harness.start(harness.manager.shutdown).raises(TimeoutError) is failure
    assert tracker.closed_with == []
    harness.start(harness.manager.__enter__).raises(RuntimeError)
    harness.start(harness.manager.wait).raises(RuntimeError)

    harness.daemon.shutdown.side_effect = None
    harness.start(harness.manager.shutdown).result()
    assert harness.daemon.shutdown.call_count == 2
    assert simulation.status is SimulationStatus.CANCELLED
    assert len(tracker.closed_with) == 1
    harness.start(harness.manager.shutdown).result()
    assert harness.daemon.shutdown.call_count == 2


def test_shutdown_rejects_future_operations(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Closed managers reject new operations, including attaching trackers."""
    harness.add(valid_inputs)
    harness.start(harness.manager.shutdown).result()
    actions: list[Callable[[], object]] = [
        lambda: harness.manager.add(*valid_inputs),
        harness.manager.wait,
        harness.manager.__enter__,
        lambda: harness.manager._attach(FakeTracker()),
    ]
    for action in actions:
        harness.start(action).raises(RuntimeError)
    assert harness.daemon.commands().count("add") == 1


def test_trackers_receive_only_runs_a_worker_accepted(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Queued runs never reach a tracker; each run is handed over once, when accepted."""
    finished = harness.add(valid_inputs)
    harness.daemon.finish("1")
    harness.poll()
    running = harness.add(valid_inputs)
    harness.daemon.accept_on_add = False
    queued = harness.add(valid_inputs, blocking=False)
    harness.poll()
    tracker = FakeTracker()

    harness.manager._attach(tracker)
    assert tracker.tracked == [running]

    later = harness.add(valid_inputs, blocking=False)
    harness.poll()
    assert tracker.tracked == [running]

    harness.daemon.set("3", state="ACCEPTED")
    harness.daemon.finish("4")  # Accepted and finished between two polls.
    harness.poll()
    harness.poll()
    assert tracker.tracked == [running, queued, later]
    assert later.succeeded

    harness.manager._detach(tracker)
    harness.manager._detach(tracker)
    harness.daemon.accept_on_add = True
    harness.add(valid_inputs)
    assert tracker.tracked == [running, queued, later]
    assert finished not in tracker.tracked


def test_shutdown_never_hands_trackers_runs_that_stayed_queued(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Cancelling a long queue costs trackers nothing; started runs still close as CANCELLED."""
    running = harness.add(valid_inputs)
    harness.daemon.accept_on_add = False
    queued = [harness.add(valid_inputs, blocking=False) for _ in range(3)]
    harness.poll()
    tracker = FakeTracker()
    harness.manager._attach(tracker)

    harness.start(harness.manager.shutdown).result()

    assert tracker.tracked == [running]
    assert [snapshot.status for snapshot in tracker.closed_with[0]] == [SimulationStatus.CANCELLED]
    assert all(simulation.status is SimulationStatus.CANCELLED for simulation in queued)


def test_shutdown_closes_trackers_after_cancelling_runs(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
) -> None:
    """Trackers see final states at close; one failing close does not skip the others."""
    simulation = harness.add(valid_inputs)
    failure = OSError("tracker close failed")
    failing, other = FakeTracker(close_error=failure), FakeTracker()
    harness.manager._attach(failing)
    harness.manager._attach(other)

    assert harness.start(harness.manager.shutdown).raises(OSError) is failure

    for tracker in (failing, other):
        assert [snapshot.status for snapshot in tracker.closed_with[0]] == [SimulationStatus.CANCELLED]
    assert simulation.is_finished
    harness.start(harness.manager.shutdown).result()
    assert len(failing.closed_with) == 1
    harness.daemon.shutdown.assert_called_once_with()


@pytest.mark.parametrize("finish_before_exit", [False, True])
def test_context_manager_keeps_completed_state(
    harness: Harness,
    valid_inputs: tuple[Path, SimulationConfig],
    *,
    finish_before_exit: bool,
) -> None:
    """Context exit cancels unfinished runs but leaves completed results unchanged."""
    simulation = harness.add(valid_inputs)
    if finish_before_exit:
        harness.daemon.finish("1")
        harness.poll()
    before = simulation.snapshot()

    def use_context() -> None:
        with harness.manager as entered:
            assert entered is harness.manager

    harness.start(use_context).result()
    if finish_before_exit:
        assert simulation.snapshot() == before
    else:
        assert simulation.status is SimulationStatus.CANCELLED
    harness.daemon.shutdown.assert_called_once_with()


class RecordingRenderer:
    """Thread-safe renderer recording final lines, for the end-to-end display check."""

    def __init__(self) -> None:
        self.lock: Lock = Lock()
        self.finished_ids: list[int] = []
        self.closed: bool = False

    def show(self, active: Sequence[SimulationSnapshot]) -> None:
        """Ignore live rows."""
        del active

    def finished(self, snapshot: SimulationSnapshot) -> None:
        """Record one final line."""
        with self.lock:
            self.finished_ids.append(snapshot.id)

    def close(self) -> None:
        """Record closure."""
        self.closed = True


def test_real_daemon_runs_a_batch_with_a_progress_display(tmp_path: Path, fake_trnrun: Path) -> None:
    """End to end through the bundled daemon, using trnrund's fake TRNRun."""
    trnexe = tmp_path / "TrnEXE64.exe"
    trnexe.touch()
    decks = [tmp_path / f"{mode}-{index}.dck" for index, mode in enumerate(("done", "done", "failed"))]
    for deck in decks:
        deck.touch()
    config = SimulationConfig(trnexe_path=trnexe)
    renderer = RecordingRenderer()

    with SimulationManager(max_concurrent=2, poll_interval=0.01, trnrun_path=fake_trnrun) as manager:
        ProgressDisplay(manager, refresh_interval=0.01, renderer=renderer)
        simulations = [manager.add(deck, config) for deck in decks]
        manager.wait()

    assert [simulation.succeeded for simulation in simulations] == [True, True, False]
    assert sorted(renderer.finished_ids) == [simulation.id for simulation in simulations]
    assert renderer.closed
    for simulation in simulations:
        assert simulation.is_finished
        assert simulation.log_count == simulation.notices + simulation.warnings + simulation.fatals
    assert simulations[0].exit_code == 0
    assert simulations[0].log_count > 0
    assert simulations[2].exit_code != 0
