# Copyright (c) 2026 His Majesty the King in Right of Canada, as represented by the Minister of Natural Resources.
# ruff: noqa: S101, SLF001

from __future__ import annotations

import time
from bisect import bisect_right
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from threading import Lock, RLock, Thread, Timer
from typing import Final, cast
from unittest.mock import Mock

import pytest

import trnrun.client as client_module
import trnrun.manager as manager_module
from trnrun.config import SimulationConfig
from trnrun.display import ProgressDisplay
from trnrun.events import LogEvent, SimulationReply, SimulationState, SimulationStatus, StatusEvent
from trnrun.manager import SimulationManager
from trnrun.simulation import Simulation, SimulationSnapshot


class FakeDaemon:
    """In-memory daemon process following the trnrund request protocol.

    Tests change daemon-side state directly, as TRNRun output and worker
    exits would, then update the manager to observe it. Like trnrund, every
    change gets the next revision, and each log entry keeps its own. Requests
    and changes are serialized, since the manager's poller sends from its own
    thread.
    """

    def __init__(self) -> None:
        self.lock: RLock = RLock()
        self.revision: int = 0
        self.runs: dict[str, dict[str, object]] = {}
        self.logs: dict[str, list[dict[str, object]]] = {}
        self.log_revisions: dict[str, list[int]] = {}
        self.requests: list[dict[str, object]] = []
        self.add_error: Exception | None = None
        self.remove_error: Exception | None = None
        self.failure: Exception | None = None
        self.shutdown: Mock = Mock()

    def request(self, request: dict[str, object]) -> dict[str, object]:
        """Answer one request like trnrund, raising for ``ok: false``."""
        with self.lock:
            return self._answer(request)

    def _answer(self, request: dict[str, object]) -> dict[str, object]:
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
            self.log_revisions[run_id] = []
            _ = self._touch(run_id)
            return {"ok": True}
        if command == "changes":
            since = request["since"]
            assert isinstance(since, int)
            changed = [self._changes(key, since) for key, run in self.runs.items() if cast("int", run["revision"]) > since]
            return {"ok": True, "revision": self.revision, "simulations": changed}
        if command == "remove":
            if self.remove_error is not None:
                error, self.remove_error = self.remove_error, None
                raise error
            if self._known(run_id)["state"] != "FINISHED":
                raise ValueError(f"Simulation has not finished: {run_id}")
            del self.runs[run_id]
            del self.logs[run_id]
            del self.log_revisions[run_id]
            return {"ok": True}
        raise ValueError(f"Unknown cmd: {command}")

    def set(self, run_id: str, **fields: object) -> None:
        """Change daemon-side fields of a run, as a new revision."""
        with self.lock:
            self.runs[run_id].update(fields)
            _ = self._touch(run_id)

    def log(self, run_id: str, severity: str = "Notice", message: str = "message") -> None:
        """Append one TRNRun log entry, as the daemon counts it."""
        with self.lock:
            self.log_revisions[run_id].append(self._touch(run_id))
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

    def fail(self, failure: Exception) -> None:
        """Make every later request raise ``failure``, as a dead daemon would."""
        with self.lock:
            self.failure = failure

    def request_count(self) -> int:
        """Return how many requests arrived so far."""
        with self.lock:
            return len(self.requests)

    def commands(self) -> list[object]:
        """Return the commands received so far."""
        with self.lock:
            return [request["cmd"] for request in self.requests]

    def sinces(self) -> list[object]:
        """Return the revision each `changes` request asked from."""
        with self.lock:
            return [request["since"] for request in self.requests if request["cmd"] == "changes"]

    def _touch(self, run_id: str) -> int:
        self.revision += 1
        self.runs[run_id]["revision"] = self.revision
        return self.revision

    def _changes(self, run_id: str, since: int) -> dict[str, object]:
        start = bisect_right(self.log_revisions[run_id], since)
        return {**self.runs[run_id], "logStart": start, "logs": self.logs[run_id][start:]}

    def _initial(self, run_id: str, request: dict[str, object]) -> dict[str, object]:
        return {
            "runId": run_id,
            "deckFile": request["deckFile"],
            "trnrunArgs": request.get("trnrunArgs", []),
            "state": "QUEUED",
            "revision": 0,
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


@dataclass
class Harness:
    """A manager whose client talks to a fake daemon."""

    manager: SimulationManager
    daemon: FakeDaemon
    daemon_factory: Mock
    inputs: tuple[Path, SimulationConfig]

    def add(self) -> Simulation:
        """Submit the valid fixture deck."""
        return self.manager.add(*self.inputs)


@pytest.fixture
def valid_inputs(tmp_path: Path) -> tuple[Path, SimulationConfig]:
    """Create harmless files satisfying submission validation."""
    deck = tmp_path / "model.dck"
    trnexe = tmp_path / "TrnEXE64.exe"
    for path in (deck, trnexe):
        path.write_text("fixture", encoding="utf-8")
    return deck, SimulationConfig(trnexe_path=trnexe, watch_tmp=True)


MANUAL: Final[float] = 3600.0  # A poll interval no test outlasts: only explicit updates run.
POLLING: Final[float] = 0.01
DEADLINE: Final[float] = 5.0  # Seconds a polling test waits before failing instead of hanging.


@pytest.fixture
def make_harness(
    monkeypatch: pytest.MonkeyPatch,
    valid_inputs: tuple[Path, SimulationConfig],
) -> Iterator[Callable[[float], Harness]]:
    """Build managers backed by fake daemons, shut down after the test."""
    managers: list[SimulationManager] = []

    def create(poll_interval: float) -> Harness:
        daemon = FakeDaemon()
        daemon_factory = Mock(return_value=daemon)
        monkeypatch.setattr(client_module, "DaemonProcess", daemon_factory)
        manager = SimulationManager(
            max_concurrent=3,
            trnrun_path="mock-trnrun.exe",
            trnrund_path="mock-daemon.exe",
            poll_interval=poll_interval,
            display=False,
        )
        managers.append(manager)
        return Harness(manager, daemon, daemon_factory, valid_inputs)

    yield create
    for manager in managers:
        manager.shutdown()


@pytest.fixture
def harness(make_harness: Callable[[float], Harness]) -> Harness:
    """A manager that updates only when the test asks it to."""
    return make_harness(MANUAL)


@pytest.fixture
def polling(make_harness: Callable[[float], Harness]) -> Harness:
    """A manager whose background thread updates it every few milliseconds."""
    return make_harness(POLLING)


def eventually(condition: Callable[[], bool]) -> None:
    """Wait for the background thread to make ``condition`` true."""
    deadline = time.monotonic() + DEADLINE
    while not condition():
        assert time.monotonic() < deadline, "condition never became true"
        time.sleep(POLLING)


def test_constructor_starts_the_configured_daemon(harness: Harness) -> None:
    """Construction passes the daemon, runner, and concurrency, and sends nothing else."""
    harness.daemon_factory.assert_called_once_with("mock-daemon.exe", "mock-trnrun.exe", 3)
    assert harness.manager.active == []
    assert harness.daemon.requests == []


def test_startup_failure_propagates(monkeypatch: pytest.MonkeyPatch) -> None:
    """A daemon startup error propagates to the caller."""
    startup_error = OSError("daemon startup failed")
    factory = Mock(side_effect=startup_error)
    monkeypatch.setattr(client_module, "DaemonProcess", factory)

    with pytest.raises(OSError, match="daemon startup failed") as raised:
        SimulationManager(max_concurrent=3, display=False)

    assert raised.value is startup_error
    factory.assert_called_once()


def test_add_sends_request_and_returns_queued_copy(harness: Harness) -> None:
    """Add returns at once with an independent config, and tracks the run."""
    deck, config = harness.inputs
    simulation = harness.add()

    assert simulation.id == 1
    assert simulation.deck_path == deck.absolute()
    assert simulation.config == config
    assert simulation.config is not config
    assert simulation.state is SimulationState.QUEUED
    assert harness.daemon.requests == [
        {
            "cmd": "add",
            "runId": "1",
            "deckFile": str(deck.absolute()),
            "trnrunArgs": simulation.config.to_cli_args(),
        },
    ]
    assert harness.manager.active == [simulation]
    active = harness.manager.active
    active.clear()
    assert harness.manager.active == [simulation]


def test_daemon_rejection_propagates_without_tracking(harness: Harness) -> None:
    """A rejected add raises the daemon's error and tracks nothing."""
    harness.daemon.add_error = ValueError("Expected .dck or .trd, got: 'model.dck'")

    with pytest.raises(ValueError, match=r"Expected \.dck or \.trd"):
        harness.add()

    assert harness.manager.active == []
    harness.daemon.add_error = None
    assert harness.add().id == 2


def test_add_rejects_invalid_paths_before_sending(harness: Harness, tmp_path: Path) -> None:
    """Invalid deck or TRNSYS paths fail before submission."""
    deck, config = harness.inputs
    with pytest.raises(FileNotFoundError, match="Deck file not found"):
        harness.manager.add(tmp_path / "missing.dck", config)
    with pytest.raises(FileNotFoundError, match="TrnEXE executable not found"):
        harness.manager.add(deck, SimulationConfig(trnexe_path=tmp_path / "missing.exe"))
    assert harness.daemon.requests == []
    assert harness.manager.active == []


def test_add_rejects_other_decks_and_targets_before_sending(harness: Harness, tmp_path: Path) -> None:
    """Only .dck and .trd decks, case-insensitively, and only daemon states are accepted."""
    _, config = harness.inputs
    text = tmp_path / "model.txt"
    text.touch()
    upper = tmp_path / "MODEL.TRD"
    upper.touch()

    with pytest.raises(ValueError, match=r"Expected a \.dck or \.trd deck"):
        harness.manager.add(text, config)
    with pytest.raises(ValueError, match="'STARTED' is not a valid SimulationState"):
        harness.manager.add(upper, config, wait_for="STARTED")  # pyright: ignore[reportArgumentType]
    assert harness.daemon.requests == []

    assert harness.manager.add(upper, config).deck_path == upper


def test_add_without_waiting_returns_before_sending(harness: Harness) -> None:
    """The run is tracked at once and sent by the next update, in the order added."""
    first = harness.manager.add(*harness.inputs, wait_for=None)
    second = harness.manager.add(*harness.inputs, wait_for=None)

    assert harness.daemon.requests == []
    assert harness.manager.active == [first, second]
    assert first.state is SimulationState.QUEUED

    _ = harness.manager.update()

    assert harness.daemon.commands() == ["add", "add", "changes"]
    assert [request["runId"] for request in harness.daemon.requests[:2]] == ["1", "2"]


def test_waiting_add_sends_earlier_runs_first(harness: Harness) -> None:
    """A run that waits never overtakes runs added before it without waiting."""
    for _ in range(2):
        _ = harness.manager.add(*harness.inputs, wait_for=None)
    third = harness.add()

    assert [request["runId"] for request in harness.daemon.requests] == ["1", "2", "3"]
    assert third.id == 3


def test_rejected_add_without_waiting_finishes_as_an_error(harness: Harness) -> None:
    """Nobody waits to catch the rejection, so the handle carries it, and later runs still go."""
    rejected = harness.manager.add(*harness.inputs, wait_for=None)
    harness.daemon.add_error = ValueError("Deck file not found")
    changed = harness.manager.update()
    harness.daemon.add_error = None
    kept = harness.add()

    assert changed == [rejected]
    assert rejected.is_finished
    assert not rejected.succeeded
    assert rejected.status_event == StatusEvent(SimulationStatus.ERROR, "Deck file not found")
    assert (rejected.exit_code, rejected.error) == (None, "Deck file not found")
    assert harness.manager.active == [kept]
    harness.manager.wait(rejected)


def test_rejection_of_an_earlier_run_does_not_fail_a_waiting_add(harness: Harness) -> None:
    """Only the waiting run's own rejection raises; earlier runs carry theirs."""
    earlier = harness.manager.add(*harness.inputs, wait_for=None)
    rejections = iter([ValueError("earlier rejected")])

    def reject_once(request: dict[str, object]) -> dict[str, object]:
        if request["cmd"] == "add" and (error := next(rejections, None)) is not None:
            harness.daemon.requests.append(request)
            raise error
        return FakeDaemon.request(harness.daemon, request)

    harness.daemon.request = reject_once  # pyright: ignore[reportAttributeAccessIssue]
    waiting = harness.add()

    assert earlier.error == "earlier rejected"
    assert harness.manager.active == [waiting]


@pytest.mark.parametrize(
    ("wait_for", "steps", "expected"),
    [
        (SimulationState.ACCEPTED, [{"state": "ACCEPTED"}], SimulationState.ACCEPTED),
        (SimulationState.RUNNING, [{"state": "ACCEPTED"}, {"state": "RUNNING"}], SimulationState.RUNNING),
        # A run that never launches skips RUNNING, which still counts as reached.
        (SimulationState.RUNNING, [{"state": "ACCEPTED"}, None], SimulationState.FINISHED),
        (SimulationState.FINISHED, [{"state": "RUNNING"}, None], SimulationState.FINISHED),
    ],
)
def test_add_waits_until_the_run_reaches_the_state(
    polling: Harness,
    wait_for: SimulationState,
    steps: list[dict[str, object] | None],
    expected: SimulationState,
) -> None:
    """The run moves on in the daemon after a delay; add returns once it reached the target or later."""

    def advance() -> None:
        for step in steps:
            time.sleep(5 * POLLING)
            if step is None:
                polling.daemon.finish("1", status="ERROR", exit_code=None, error="launch failed")
            else:
                polling.daemon.set("1", **step)

    mover = Thread(target=advance)
    mover.start()
    simulation = polling.manager.add(*polling.inputs, wait_for=wait_for, timeout=DEADLINE)
    mover.join()

    assert simulation.state is expected


def test_add_times_out_with_the_run_still_submitted(polling: Harness) -> None:
    """A timeout stops the wait, not the run."""
    with pytest.raises(TimeoutError, match="did not reach ACCEPTED"):
        polling.manager.add(*polling.inputs, wait_for=SimulationState.ACCEPTED, timeout=10 * POLLING)

    (simulation,) = polling.manager.active
    assert simulation.state is SimulationState.QUEUED
    assert polling.daemon.commands()[0] == "add"


def test_add_waiting_raises_when_shut_down(polling: Harness) -> None:
    """Shutdown wakes an add that waits, like any waiter."""
    timer = Timer(10 * POLLING, polling.manager.shutdown)
    timer.start()

    with pytest.raises(RuntimeError, match="SimulationManager is closed"):
        polling.manager.add(*polling.inputs, wait_for=SimulationState.FINISHED, timeout=DEADLINE)
    timer.join()


def test_update_without_runs_sends_nothing(harness: Harness) -> None:
    """An idle manager never bothers the daemon."""
    harness.manager.update()

    assert harness.daemon.requests == []


def test_update_asks_one_question_for_the_changes_since_the_last(harness: Harness) -> None:
    """Each update is one request from the previous revision, returning the handles that changed."""
    first, second = harness.add(), harness.add()
    harness.daemon.requests.clear()
    assert harness.manager.update() == []  # Submissions are no news: handles start queued.
    assert harness.daemon.requests == [{"cmd": "changes", "since": 0}]

    harness.daemon.set("1", state="RUNNING", status={"status": "RUNNING", "message": "launched"})
    assert harness.manager.update() == [first]
    assert harness.manager.update() == []

    assert harness.daemon.sinces() == [0, 2, 3]
    assert (first.state, second.state) == (SimulationState.RUNNING, SimulationState.QUEUED)
    assert first.status_event == StatusEvent(SimulationStatus.RUNNING, "launched")


def test_update_returns_finished_runs_in_submission_order(harness: Harness) -> None:
    """Every run that finished is reported once, even when it never seemed to run."""
    first, second, third = [harness.add() for _ in range(3)]
    harness.daemon.finish("3")
    harness.daemon.finish("1")

    assert harness.manager.update() == [first, third]
    assert harness.manager.active == [second]


def test_started_holds_only_runs_a_worker_took_until_they_finish(harness: Harness) -> None:
    """Runs join `started` when accepted, in the order seen, and leave it when finished; queued ones never join."""
    first, second, third = [harness.add() for _ in range(3)]
    _ = harness.manager.add(*harness.inputs, wait_for=None)  # Not even sent yet.
    _ = harness.manager.update()
    assert harness.manager.started == []

    harness.daemon.set("2", state="ACCEPTED")
    _ = harness.manager.update()
    harness.daemon.set("1", state="RUNNING")
    harness.daemon.set("2", state="RUNNING")
    _ = harness.manager.update()
    assert harness.manager.started == [second, first]

    harness.daemon.finish("2")
    harness.daemon.finish("3")  # Finished without being seen to start: never joins.
    _ = harness.manager.update()
    assert harness.manager.started == [first]
    assert third.is_finished

    started = harness.manager.started
    started.clear()
    assert harness.manager.started == [first]  # A copy.

    harness.manager.shutdown()
    assert harness.manager.started == []


def test_update_brings_only_new_logs(harness: Harness) -> None:
    """Each update receives only the entries that arrived since the previous one."""
    simulation = harness.add()
    harness.daemon.set("1", state="RUNNING")
    harness.daemon.log("1", "Notice", "one")
    harness.daemon.log("1", "Warning", "two")
    _ = harness.manager.update()
    assert [event.message for event in simulation.logs] == ["one", "two"]

    harness.daemon.log("1", "Fatal", "three")
    _ = harness.manager.update()
    _ = harness.manager.update()

    assert simulation.logs == [
        LogEvent("Notice", 0.0, message="one"),
        LogEvent("Warning", 0.0, message="two"),
        LogEvent("Fatal", 0.0, message="three"),
    ]
    assert (simulation.notices, simulation.warnings, simulation.fatals) == (1, 1, 1)


def test_failed_update_is_repeated_without_duplicating_logs(harness: Harness) -> None:
    """A failure mid-update keeps the cursor, so the next update repeats changes that handles absorb."""
    running, finished = harness.add(), harness.add()
    harness.daemon.set("1", state="RUNNING")
    harness.daemon.log("1", "Notice", "once")
    harness.daemon.finish("2")
    harness.daemon.remove_error = ValueError("remove failed")

    with pytest.raises(ValueError, match="remove failed"):
        _ = harness.manager.update()
    assert [event.message for event in running.logs] == ["once"]

    assert harness.manager.update() == []  # Both already applied; the finished one is removed now.
    assert [event.message for event in running.logs] == ["once"]
    assert finished.succeeded
    assert harness.manager.active == [running]
    assert harness.daemon.sinces() == [0, 0]


def test_finished_run_arrives_with_its_final_logs_and_is_removed(harness: Harness) -> None:
    """Completion arrives with the remaining logs; the daemon and the manager forget the run."""
    simulation = harness.add()
    harness.daemon.set("1", state="RUNNING")
    harness.daemon.log("1", "Notice", "early")
    harness.manager.update()
    harness.daemon.log("1", "Warning", "late")
    harness.daemon.finish("1", exit_code=0)
    harness.manager.update()

    assert simulation.snapshot().is_finished
    assert simulation.succeeded
    assert simulation.exit_code == 0
    assert [event.message for event in simulation.logs] == ["early", "late"]
    assert harness.daemon.runs == {}
    assert harness.daemon.requests[-1] == {"cmd": "remove", "runId": "1"}
    assert harness.manager.active == []

    harness.daemon.requests.clear()
    harness.manager.update()
    assert harness.daemon.requests == []  # Nothing is left to poll.


def test_results_follow_the_daemon_verdict(harness: Harness) -> None:
    """A DONE status with a failing exit code or daemon error is not a success."""
    done, nonzero, error, unlaunched = [harness.add() for _ in range(4)]
    harness.daemon.finish("1")
    harness.daemon.finish("2", exit_code=7)
    harness.daemon.finish("3", error="capture failed")
    harness.daemon.finish("4", status="ERROR", exit_code=None, error="launch failed")
    harness.manager.update()

    assert [simulation.succeeded for simulation in (done, nonzero, error, unlaunched)] == [True, False, False, False]
    assert nonzero.status is SimulationStatus.DONE
    assert (unlaunched.exit_code, unlaunched.error) == (None, "launch failed")
    assert harness.manager.active == []


def test_background_updates_move_handles_without_waiting(polling: Harness) -> None:
    """Handles follow the daemon on their own, as a notebook cell that never waits needs."""
    simulation = polling.add()
    polling.daemon.set("1", state="RUNNING", progress={"time": 5, "percent": 0.5, "elapsedMs": 1, "etaMs": 1})
    eventually(lambda: simulation.progress is not None)

    polling.daemon.finish("1")
    eventually(lambda: simulation.is_finished)

    assert simulation.succeeded
    assert polling.manager.active == []
    assert polling.manager.failure is None


def test_idle_background_updates_send_nothing(polling: Harness) -> None:
    """With nothing tracked, the poller never bothers the daemon."""
    time.sleep(10 * POLLING)

    assert polling.daemon.request_count() == 0


def test_wait_returns_once_the_selected_runs_finish(polling: Harness) -> None:
    """Waiting for some runs does not depend on the others."""
    first, second, third = [polling.add() for _ in range(3)]
    polling.daemon.finish("1")
    polling.daemon.finish("2")

    polling.manager.wait(first, second, timeout=DEADLINE)

    assert first.succeeded
    assert second.succeeded
    assert not third.is_finished
    assert polling.manager.active == [third]


def test_wait_without_arguments_waits_for_every_tracked_run(polling: Harness) -> None:
    """With no argument, wait returns once nothing is unfinished."""
    first, second = polling.add(), polling.add()
    polling.daemon.finish("2")
    polling.daemon.finish("1")

    polling.manager.wait(timeout=DEADLINE)

    assert first.is_finished
    assert second.is_finished
    assert polling.manager.active == []


def test_wait_without_runs_returns_without_requests(harness: Harness) -> None:
    """An empty completion scope returns at once."""
    harness.manager.wait()

    assert harness.daemon.requests == []


def test_wait_times_out_while_runs_are_unfinished(polling: Harness) -> None:
    """A timeout bounds the wait; the run keeps going."""
    simulation = polling.add()

    with pytest.raises(TimeoutError, match="did not finish"):
        polling.manager.wait(simulation, timeout=10 * POLLING)

    assert polling.manager.active == [simulation]


def test_wait_raises_when_shut_down_from_another_thread(polling: Harness) -> None:
    """Shutdown wakes a waiter, which never mistakes the forgotten runs for finished ones."""
    polling.add()
    timer = Timer(10 * POLLING, polling.manager.shutdown)
    timer.start()

    with pytest.raises(RuntimeError, match="SimulationManager is closed"):
        polling.manager.wait(timeout=DEADLINE)
    timer.join()


@pytest.mark.parametrize("interval", ["poll_interval", "refresh_interval"])
@pytest.mark.parametrize("value", [0.0, -1.0, float("nan")])
def test_constructor_rejects_nonpositive_intervals(monkeypatch: pytest.MonkeyPatch, interval: str, value: float) -> None:
    """Both intervals must be positive, checked before the daemon starts."""
    factory = Mock()
    monkeypatch.setattr(client_module, "DaemonProcess", factory)

    with pytest.raises(ValueError, match=f"{interval} must be positive"):
        SimulationManager(**{interval: value})  # pyright: ignore[reportArgumentType]
    factory.assert_not_called()


def test_wait_rejects_foreign_unfinished_handles_even_when_ids_match(harness: Harness) -> None:
    """Wait uses identity for unfinished runs; any finished handle returns at once."""
    owned = harness.add()
    outsider = Simulation(*harness.inputs, sim_id=owned.id)
    with pytest.raises(ValueError, match="does not belong"):
        harness.manager.wait(outsider)

    assert outsider.apply(
        SimulationReply(SimulationState.FINISHED, status=StatusEvent(SimulationStatus.CANCELLED)),
    )
    harness.manager.wait(outsider)


def test_daemon_failure_raises_and_preserves_handles(polling: Harness) -> None:
    """A dead daemon stops the poller and raises from every call; handles keep their last reply."""
    running = polling.add()
    polling.daemon.set(
        "1",
        state="RUNNING",
        status={"status": "RUNNING", "message": "still running"},
        progress={"time": 5, "percent": 0.5, "elapsedMs": 1, "etaMs": 1},
    )
    polling.daemon.log("1", "Warning", "retained")
    eventually(lambda: running.log_count == 1)
    before = (running._reply, running.snapshot(), running.logs)

    failure = RuntimeError("TRNRun daemon exited with code 1")
    polling.daemon.fail(failure)
    eventually(lambda: polling.manager.failure is failure)
    for action in (polling.manager.update, polling.manager.wait, polling.add):
        with pytest.raises(RuntimeError) as raised:
            action()
        assert raised.value is failure

    assert (running._reply, running.snapshot(), running.logs) == before
    assert running.state is SimulationState.RUNNING
    assert polling.manager.active == [running]
    requests = polling.daemon.request_count()
    time.sleep(10 * POLLING)
    assert polling.daemon.request_count() == requests  # The poller stopped.


def test_shutdown_stops_the_poller(polling: Harness) -> None:
    """Shutdown joins the background thread without recording its interrupted update as a failure."""
    polling.add()
    eventually(lambda: polling.daemon.request_count() > 1)

    polling.manager.shutdown()

    assert not polling.manager._poller.is_alive()
    assert polling.manager.failure is None


def test_shutdown_kills_the_daemon_and_preserves_handles(harness: Harness) -> None:
    """Shutdown forgets active runs without synthesizing completion, and runs once."""
    finished, running = harness.add(), harness.add()
    harness.daemon.finish("1")
    harness.daemon.set("2", state="RUNNING", status={"status": "RUNNING", "message": ""})
    harness.daemon.log("2", "Notice", "retained")
    harness.manager.update()
    before = (running._reply, running.snapshot(), running.logs)

    harness.manager.shutdown()
    harness.manager.shutdown()

    harness.daemon.shutdown.assert_called_once_with()
    assert harness.manager.active == []
    assert finished.succeeded
    assert (running._reply, running.snapshot(), running.logs) == before
    assert not running.is_finished


def test_shutdown_rejects_future_operations(harness: Harness) -> None:
    """Closed managers reject new operations without contacting the daemon."""
    harness.add()
    harness.manager.shutdown()
    harness.daemon.requests.clear()

    actions: list[Callable[[], object]] = [
        harness.add,
        harness.manager.update,
        harness.manager.wait,
        harness.manager.__enter__,
    ]
    for action in actions:
        with pytest.raises(RuntimeError, match="SimulationManager is closed"):
            action()
    assert harness.daemon.requests == []


def test_shutdown_failure_propagates_and_leaves_the_manager_closed(harness: Harness) -> None:
    """A failed daemon cleanup raises once; the manager stays closed and later calls do nothing."""
    simulation = harness.add()
    failure = TimeoutError("daemon did not exit")
    harness.daemon.shutdown.side_effect = failure

    with pytest.raises(TimeoutError) as raised:
        harness.manager.shutdown()
    harness.manager.shutdown()

    assert raised.value is failure
    harness.daemon.shutdown.assert_called_once_with()
    assert harness.manager.active == []
    assert simulation.state is SimulationState.QUEUED
    with pytest.raises(RuntimeError):
        harness.manager.__enter__()


def test_context_manager_shuts_down_on_exit(harness: Harness) -> None:
    """The context returns the manager and kills the daemon on exit."""
    with harness.manager as entered:
        assert entered is harness.manager

    harness.daemon.shutdown.assert_called_once_with()


def test_client_reaches_the_same_daemon(harness: Harness) -> None:
    """The exposed client sends through the manager's daemon."""
    harness.add()

    assert list(harness.manager.client.changes().simulations) == ["1"]


@pytest.fixture
def fake_daemon(monkeypatch: pytest.MonkeyPatch) -> FakeDaemon:
    """Back every manager built in the test with one fake daemon."""
    daemon = FakeDaemon()
    monkeypatch.setattr(client_module, "DaemonProcess", Mock(return_value=daemon))
    return daemon


@pytest.fixture
def display_factory(monkeypatch: pytest.MonkeyPatch) -> Mock:
    """Replace the manager's display class with a mock."""
    factory = Mock()
    monkeypatch.setattr(manager_module, "ProgressDisplay", factory)
    return factory


def test_display_is_on_by_default(fake_daemon: FakeDaemon, display_factory: Mock) -> None:
    """A manager shows its own runs, with the default renderer and interval."""
    del fake_daemon
    with SimulationManager() as manager:
        display_factory.assert_called_once_with(manager, refresh_interval=1.0, renderer=None)
        assert manager.display is display_factory.return_value


def test_display_takes_a_renderer_and_interval(fake_daemon: FakeDaemon, display_factory: Mock) -> None:
    """A renderer passed as display draws the built-in display."""
    del fake_daemon
    renderer = RecordingRenderer()
    with SimulationManager(display=renderer, refresh_interval=0.5) as manager:
        display_factory.assert_called_once_with(manager, refresh_interval=0.5, renderer=renderer)


def test_display_false_shows_nothing(fake_daemon: FakeDaemon, display_factory: Mock) -> None:
    """A GUI turns the built-in display off."""
    del fake_daemon
    with SimulationManager(display=False) as manager:
        display_factory.assert_not_called()
        assert manager.display is None


def test_shutdown_kills_the_daemon_then_closes_the_display(
    fake_daemon: FakeDaemon,
    display_factory: Mock,
) -> None:
    """The kill frees any update blocked on the daemon; both are released once."""
    order: list[str] = []
    display_factory.return_value.close.side_effect = lambda: order.append("display")
    fake_daemon.shutdown.side_effect = lambda: order.append("daemon")

    with SimulationManager():
        pass
    assert order == ["daemon", "display"]


def test_shutdown_closes_the_display_when_the_daemon_fails_to_exit(
    fake_daemon: FakeDaemon,
    display_factory: Mock,
) -> None:
    """A daemon cleanup failure propagates after the display and the poller are released."""
    failure = TimeoutError("daemon did not exit")
    fake_daemon.shutdown.side_effect = failure
    manager = SimulationManager()

    with pytest.raises(TimeoutError) as raised:
        manager.shutdown()

    assert raised.value is failure
    display_factory.return_value.close.assert_called_once_with()
    assert not manager._poller.is_alive()


def test_display_failure_at_construction_kills_the_daemon(
    fake_daemon: FakeDaemon,
    display_factory: Mock,
) -> None:
    """A display that cannot start, such as a notebook without IPython, does not leak the daemon."""
    failure = ImportError("Notebook display mode requires IPython")
    display_factory.side_effect = failure

    with pytest.raises(ImportError) as raised:
        SimulationManager()

    assert raised.value is failure
    fake_daemon.shutdown.assert_called_once_with()


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

    with SimulationManager(
        max_concurrent=2,
        trnrun_path=fake_trnrun,
        poll_interval=0.01,
        display=renderer,
        refresh_interval=0.01,
    ) as manager:
        assert isinstance(manager.display, ProgressDisplay)
        simulations = [manager.add(deck, config) for deck in decks]
        manager.wait(timeout=30)

    assert [simulation.succeeded for simulation in simulations] == [True, True, False]
    # A run accepted and finished between two redraws gets no line, so only check for repeats.
    assert len(set(renderer.finished_ids)) == len(renderer.finished_ids)
    assert set(renderer.finished_ids) <= {simulation.id for simulation in simulations}
    assert renderer.closed
    for simulation in simulations:
        assert simulation.is_finished
        assert simulation.log_count == simulation.notices + simulation.warnings + simulation.fatals
    assert simulations[0].exit_code == 0
    assert simulations[0].log_count > 0
    assert simulations[2].exit_code != 0
