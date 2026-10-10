# Copyright (c) 2026 His Majesty the King in Right of Canada, as represented by the Minister of Natural Resources.
# ruff: noqa: S101, SLF001

from __future__ import annotations

import logging
import time
from collections.abc import Callable, Iterator, Sequence
from dataclasses import dataclass
from pathlib import Path
from threading import Event, Lock, RLock, Thread, Timer
from typing import Final
from unittest.mock import Mock

import pytest

import trnrun.client as client_module
import trnrun.convenience.display as display_module
from trnrun.config import SimulationConfig
from trnrun.convenience.manager import SimulationManager
from trnrun.convenience.simulation import Simulation
from trnrun.events import LogEvent, SimulationReply, SimulationState, SimulationStatus, StatusEvent


class FakeDaemon:
    """In-memory daemon process following the trnrund request protocol.

    Tests change daemon-side state directly, as TRNRun output and worker
    exits would, then update the manager to observe it. Like trnrund, each
    `pull` returns the runs changed since they were last pulled, with only the
    log entries not pulled before, then forgets the finished ones. Requests
    and changes are serialized, since the manager's poller sends from its own
    thread.
    """

    def __init__(self) -> None:
        self.lock: RLock = RLock()
        self.runs: dict[str, dict[str, object]] = {}
        self.logs: dict[str, list[dict[str, object]]] = {}
        self.pulled_logs: dict[str, int] = {}
        self.changed: set[str] = set()
        self.requests: list[dict[str, object]] = []
        self.add_error: Exception | None = None
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
        if command == "add":
            run_id = str(request["runId"])
            if self.add_error is not None:
                raise self.add_error
            if run_id in self.runs:
                raise ValueError(f"Invalid or duplicate runId: {run_id}")
            self.runs[run_id] = self._initial(run_id, request)
            self.logs[run_id] = []
            self.pulled_logs[run_id] = 0
            self.changed.add(run_id)
            return {"ok": True}
        if command == "pull":
            return {"ok": True, "simulations": self._pull()}
        raise ValueError(f"Unknown cmd: {command}")

    def set(self, run_id: str, **fields: object) -> None:
        """Change daemon-side fields of a run."""
        with self.lock:
            self.runs[run_id].update(fields)
            self.changed.add(run_id)

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
            self.changed.add(run_id)

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

    def _pull(self) -> list[dict[str, object]]:
        """Return the changed runs in submission order, with unpulled logs, then forget finished ones."""
        pulled: list[dict[str, object]] = []
        for run_id in [run_id for run_id in self.runs if run_id in self.changed]:
            start = self.pulled_logs[run_id]
            pulled.append({**self.runs[run_id], "logs": self.logs[run_id][start:]})
            self.pulled_logs[run_id] = len(self.logs[run_id])
            if self.runs[run_id]["state"] == "FINISHED":
                del self.runs[run_id], self.logs[run_id], self.pulled_logs[run_id]
        self.changed.clear()
        return pulled

    def _initial(self, run_id: str, request: dict[str, object]) -> dict[str, object]:
        return {
            "runId": run_id,
            "deckFile": request["deckFile"],
            "trnrunArgs": request.get("trnrunArgs", []),
            "state": "QUEUED",
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


MANUAL: Final[float] = 3600.0  # A poll interval no test outlasts: only explicit `_sync()` calls run.
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
    """Add sends the run, returns with an independent config, and tracks the run."""
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


def test_add_rejects_a_missing_trnsys_before_sending(harness: Harness, tmp_path: Path) -> None:
    """A missing TRNSYS executable fails before submission; the daemon checks decks."""
    deck, _ = harness.inputs
    with pytest.raises(FileNotFoundError, match="TrnEXE executable not found"):
        harness.manager.add(deck, SimulationConfig(trnexe_path=tmp_path / "missing.exe"))
    assert harness.daemon.requests == []
    assert harness.manager.active == []


def test_update_without_runs_sends_nothing(harness: Harness) -> None:
    """An idle manager never bothers the daemon."""
    assert harness.manager._sync() == []

    assert harness.daemon.requests == []


def test_update_pulls_once_for_the_changes_since_the_last(harness: Harness) -> None:
    """Each update is one request, returning the handles that changed since the previous one."""
    first, second = harness.add(), harness.add()
    harness.daemon.requests.clear()
    assert harness.manager._sync() == [first, second]  # Each submission is reported once, queued.
    assert harness.daemon.requests == [{"cmd": "pull"}]

    harness.daemon.set("1", state="RUNNING", status={"status": "RUNNING", "message": "launched"})
    assert harness.manager._sync() == [first]
    assert harness.manager._sync() == []

    assert harness.daemon.commands() == ["pull"] * 3
    assert (first.state, second.state) == (SimulationState.RUNNING, SimulationState.QUEUED)
    assert first.status_event == StatusEvent(SimulationStatus.RUNNING, "launched")


def test_update_returns_finished_runs_in_submission_order(harness: Harness) -> None:
    """Every run that finished is reported once, even when it never seemed to run."""
    first, second, third = [harness.add() for _ in range(3)]
    _ = harness.manager._sync()
    harness.daemon.finish("3")
    harness.daemon.finish("1")

    assert harness.manager._sync() == [first, third]
    assert harness.manager.active == [second]


def test_reads_never_wait_on_a_stalled_daemon(harness: Harness) -> None:
    """While a poll waits for the daemon's reply, readers never wait."""
    simulation = harness.add()
    asked, release = Event(), Event()

    def stall_pull(request: dict[str, object]) -> dict[str, object]:
        if request["cmd"] == "pull":
            asked.set()
            assert release.wait(DEADLINE)
        return FakeDaemon.request(harness.daemon, request)

    harness.daemon.request = stall_pull  # pyright: ignore[reportAttributeAccessIssue]
    updater = Thread(target=harness.manager._sync)
    updater.start()
    try:
        assert asked.wait(DEADLINE)
        started = time.monotonic()
        assert harness.manager.active == [simulation]
        assert simulation.info.state is SimulationState.QUEUED
        assert time.monotonic() - started < DEADLINE / 2
    finally:
        release.set()
        updater.join()


def test_update_brings_only_new_logs(harness: Harness) -> None:
    """Each update receives only the entries that arrived since the previous one."""
    simulation = harness.add()
    harness.daemon.set("1", state="RUNNING")
    harness.daemon.log("1", "Notice", "one")
    harness.daemon.log("1", "Warning", "two")
    _ = harness.manager._sync()
    assert [event.message for event in simulation.logs] == ["one", "two"]

    harness.daemon.log("1", "Fatal", "three")
    _ = harness.manager._sync()
    _ = harness.manager._sync()

    assert simulation.logs == [
        LogEvent("Notice", 0.0, message="one"),
        LogEvent("Warning", 0.0, message="two"),
        LogEvent("Fatal", 0.0, message="three"),
    ]
    assert (simulation.notices, simulation.warnings, simulation.fatals) == (1, 1, 1)


def test_finished_run_arrives_with_its_final_logs_and_is_forgotten(harness: Harness) -> None:
    """Completion arrives with the remaining logs; the daemon and the manager then forget the run."""
    simulation = harness.add()
    harness.daemon.set("1", state="RUNNING")
    harness.daemon.log("1", "Notice", "early")
    _ = harness.manager._sync()
    harness.daemon.log("1", "Warning", "late")
    harness.daemon.finish("1", exit_code=0)
    _ = harness.manager._sync()

    assert simulation.info.state is SimulationState.FINISHED
    assert simulation.succeeded
    assert simulation.exit_code == 0
    assert [event.message for event in simulation.logs] == ["early", "late"]
    assert harness.daemon.runs == {}
    assert harness.daemon.commands() == ["add", "pull", "pull"]  # Nothing to clean up.
    assert harness.manager.active == []

    harness.daemon.requests.clear()
    _ = harness.manager._sync()
    assert harness.daemon.requests == []  # Nothing is left to poll.


def test_results_follow_the_daemon_verdict(harness: Harness) -> None:
    """A DONE status with a failing exit code or daemon error is not a success."""
    done, nonzero, error, unlaunched = [harness.add() for _ in range(4)]
    harness.daemon.finish("1")
    harness.daemon.finish("2", exit_code=7)
    harness.daemon.finish("3", error="capture failed")
    harness.daemon.finish("4", status="ERROR", exit_code=None, error="launch failed")
    _ = harness.manager._sync()

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
    eventually(lambda: polling.manager.active == [])
    assert polling.manager._poller.is_alive()  # Still syncing.


def test_idle_background_updates_send_nothing(polling: Harness) -> None:
    """With nothing tracked, the poller never bothers the daemon."""
    time.sleep(10 * POLLING)

    assert polling.daemon.request_count() == 0


def test_simulation_wait_returns_once_its_run_finishes(polling: Harness) -> None:
    """Waiting for some runs does not depend on the others."""
    first, second, third = [polling.add() for _ in range(3)]
    polling.daemon.finish("1")
    polling.daemon.finish("2")

    first.wait(DEADLINE)
    second.wait(DEADLINE)

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
    """A timeout bounds either wait; the run keeps going."""
    simulation = polling.add()

    with pytest.raises(TimeoutError, match="did not finish"):
        polling.manager.wait(timeout=10 * POLLING)
    with pytest.raises(TimeoutError, match="did not finish"):
        simulation.wait(10 * POLLING)

    assert polling.manager.active == [simulation]


def test_wait_raises_when_shut_down_from_another_thread(polling: Harness) -> None:
    """Shutdown settles the unfinished handles, so both waits raise instead of hanging."""
    simulation = polling.add()
    timer = Timer(10 * POLLING, polling.manager.shutdown)
    timer.start()

    with pytest.raises(RuntimeError, match="SimulationManager is closed"):
        polling.manager.wait(timeout=DEADLINE)
    timer.join()
    with pytest.raises(RuntimeError, match="SimulationManager is closed"):
        simulation.wait(DEADLINE)
    assert not simulation.is_finished  # Its last reply is kept, not marked finished.


@pytest.mark.parametrize("value", [0.0, -1.0, float("nan")])
def test_constructor_rejects_nonpositive_poll_intervals(monkeypatch: pytest.MonkeyPatch, value: float) -> None:
    """The poll interval must be positive, checked before the daemon starts."""
    factory = Mock()
    monkeypatch.setattr(client_module, "DaemonProcess", factory)

    with pytest.raises(ValueError, match="poll_interval must be positive"):
        SimulationManager(poll_interval=value)
    factory.assert_not_called()


def test_daemon_failure_kills_it_settles_handles_and_raises(polling: Harness) -> None:
    """A failed pull kills the daemon and settles the unfinished handles with its error; they keep their last reply."""
    running = polling.add()
    polling.daemon.set(
        "1",
        state="RUNNING",
        status={"status": "RUNNING", "message": "still running"},
        progress={"time": 5, "percent": 0.5, "elapsedMs": 1, "etaMs": 1},
    )
    polling.daemon.log("1", "Warning", "retained")
    eventually(lambda: running.log_count == 1)
    before = (running.info, running.logs)

    failure = RuntimeError("TRNRun daemon exited with code 1")
    polling.daemon.fail(failure)
    eventually(lambda: not polling.manager._poller.is_alive())
    polling.daemon.shutdown.assert_called_once_with()  # Killed, so no run goes on untracked.
    for action in (polling.manager.wait, running.wait):
        with pytest.raises(RuntimeError) as raised:
            action()
        assert raised.value is failure
    with pytest.raises(RuntimeError):
        _ = polling.add()  # The daemon refuses it; nothing is tracked.

    assert (running.info, running.logs) == before
    assert running.state is SimulationState.RUNNING
    assert polling.manager.active == [running]

    polling.manager.shutdown()
    with pytest.raises(RuntimeError) as raised:
        running.wait()
    assert raised.value is failure  # Shutdown keeps the first error.


def test_shutdown_stops_the_poller(polling: Harness) -> None:
    """Shutdown joins the background thread, which takes its interrupted pull for shutdown, not a failure."""
    simulation = polling.add()
    eventually(lambda: polling.daemon.request_count() > 1)

    polling.manager.shutdown()

    assert not polling.manager._poller.is_alive()
    with pytest.raises(RuntimeError, match="SimulationManager is closed"):
        simulation.wait(0)


def test_shutdown_kills_the_daemon_and_preserves_handles(harness: Harness) -> None:
    """Shutdown forgets active runs without synthesizing completion, and runs once."""
    finished, running = harness.add(), harness.add()
    harness.daemon.finish("1")
    harness.daemon.set("2", state="RUNNING", status={"status": "RUNNING", "message": ""})
    harness.daemon.log("2", "Notice", "retained")
    _ = harness.manager._sync()
    before = (running.info, running.logs)

    harness.manager.shutdown()
    harness.manager.shutdown()

    harness.daemon.shutdown.assert_called_once_with()
    assert harness.manager.active == []
    assert finished.succeeded
    assert (running.info, running.logs) == before
    assert not running.is_finished


def test_shutdown_rejects_future_operations(harness: Harness) -> None:
    """Closed managers reject new operations without contacting the daemon."""
    harness.add()
    harness.manager.shutdown()
    harness.daemon.requests.clear()

    actions: list[Callable[[], object]] = [
        harness.add,
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


# -----------------------------------------------------------------
# Display
# -----------------------------------------------------------------
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
    monkeypatch.setattr(display_module, "ProgressDisplay", factory)
    return factory


def test_display_is_on_by_default(fake_daemon: FakeDaemon, display_factory: Mock) -> None:
    """A manager shows its own runs with the built-in display."""
    del fake_daemon
    with SimulationManager() as manager:
        display_factory.assert_called_once_with()
        assert manager.display is display_factory.return_value


def test_display_false_shows_nothing(fake_daemon: FakeDaemon, display_factory: Mock) -> None:
    """A GUI turns the built-in display off."""
    del fake_daemon
    with SimulationManager(display=False) as manager:
        display_factory.assert_not_called()
        assert manager.display is None


def test_display_receives_the_runs_each_poll_changed(harness: Harness) -> None:
    """A custom display is updated with the changed handles, never for a poll that changed nothing."""
    display = Mock(spec=["update", "close"])
    harness.manager.display = display
    first, second = harness.add(), harness.add()
    _ = harness.manager._sync()
    display.update.assert_called_once_with([first, second])
    display.update.reset_mock()
    _ = harness.manager._sync()
    display.update.assert_not_called()

    harness.daemon.set("2", state="RUNNING")
    harness.daemon.finish("1")
    _ = harness.manager._sync()

    display.update.assert_called_once_with([first, second])

    harness.manager.shutdown()
    display.close.assert_called_once_with()


def test_finished_handles_settle_after_the_display_shows_them(harness: Harness) -> None:
    """A wait returns only once the display printed the final line, so later output follows it."""
    simulation = harness.add()
    settled_during_update: list[bool] = []
    display = Mock(spec=["update", "close"])
    display.update.side_effect = lambda _changed: settled_during_update.append(simulation._settled.is_set())
    harness.manager.display = display
    harness.daemon.finish("1")

    _ = harness.manager._sync()

    assert settled_during_update == [False]
    simulation.wait(0)


def test_manager_wait_during_the_final_display_update_times_out(polling: Harness) -> None:
    """Even a wait started after the final reply must wait for its display update."""
    updating = Event()
    release = Event()

    def stall_update(changed: Sequence[Simulation]) -> None:
        if any(simulation.is_finished for simulation in changed):
            updating.set()
            assert release.wait(DEADLINE), "display update was not released"

    display = Mock(spec=["update", "close"])
    display.update.side_effect = stall_update
    polling.manager.display = display
    simulation = polling.add()
    polling.daemon.finish("1")

    try:
        assert updating.wait(DEADLINE), "final display update never started"
        assert simulation.is_finished
        assert polling.manager.active == []
        with pytest.raises(TimeoutError, match="did not finish"):
            simulation.wait(0)
        with pytest.raises(TimeoutError, match="did not finish"):
            polling.manager.wait(timeout=0)
    finally:
        release.set()

    polling.manager.wait(timeout=DEADLINE)
    simulation.wait(0)


@pytest.mark.parametrize("fail_on_finish", [False, True])
def test_display_failure_is_logged_and_updates_continue(
    harness: Harness,
    caplog: pytest.LogCaptureFixture,
    *,
    fail_on_finish: bool,
) -> None:
    """A failing display never stops the handles from following the daemon."""
    failure = RuntimeError("render failed")
    display = Mock(spec=["update", "close"])
    display.update.side_effect = [None, failure] if fail_on_finish else [failure, None]
    harness.manager.display = display
    simulation = harness.add()
    harness.daemon.set("1", state="RUNNING")

    with caplog.at_level(logging.ERROR, logger="trnrun.convenience.manager"):
        assert harness.manager._sync() == [simulation]
        harness.daemon.finish("1")
        assert harness.manager._sync() == [simulation]

    assert [record.exc_info[1] for record in caplog.records if record.exc_info] == [failure]
    assert display.update.call_count == 2
    assert simulation.succeeded
    assert harness.manager.active == []
    harness.manager.wait(timeout=0)
    simulation.wait(0)


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


def test_display_failure_at_construction_starts_no_daemon(
    monkeypatch: pytest.MonkeyPatch,
    display_factory: Mock,
) -> None:
    """A display that cannot start, such as a notebook without IPython, leaves no daemon behind."""
    daemon_factory = Mock()
    monkeypatch.setattr(client_module, "DaemonProcess", daemon_factory)
    failure = ImportError("Notebook display mode requires IPython")
    display_factory.side_effect = failure

    with pytest.raises(ImportError) as raised:
        SimulationManager()

    assert raised.value is failure
    daemon_factory.assert_not_called()


class RecordingDisplay:
    """Thread-safe display recording finished runs, for the end-to-end check."""

    def __init__(self) -> None:
        self.lock: Lock = Lock()
        self.finished_ids: list[int] = []
        self.closed: bool = False

    def update(self, changed: Sequence[Simulation]) -> None:
        """Record the runs that finished."""
        with self.lock:
            self.finished_ids.extend(simulation.id for simulation in changed if simulation.is_finished)

    def close(self) -> None:
        """Record closure."""
        self.closed = True


def test_real_daemon_runs_a_batch_with_a_display(tmp_path: Path, fake_trnrun: Path) -> None:
    """End to end through the bundled daemon, using trnrund's fake TRNRun."""
    trnexe = tmp_path / "TrnEXE64.exe"
    trnexe.touch()
    decks = [tmp_path / f"{mode}-{index}.dck" for index, mode in enumerate(("done", "done", "failed"))]
    for deck in decks:
        deck.touch()
    config = SimulationConfig(trnexe_path=trnexe)
    display = RecordingDisplay()

    with SimulationManager(max_concurrent=2, trnrun_path=fake_trnrun, poll_interval=0.01, display=display) as manager:
        simulations = [manager.add(deck, config) for deck in decks]
        manager.wait(timeout=30)

    assert [simulation.succeeded for simulation in simulations] == [True, True, False]
    # Every finished run reaches the display exactly once.
    assert sorted(display.finished_ids) == [simulation.id for simulation in simulations]
    assert display.closed
    for simulation in simulations:
        assert simulation.is_finished
        assert simulation.log_count == simulation.notices + simulation.warnings + simulation.fatals
    assert simulations[0].exit_code == 0
    assert simulations[0].log_count > 0
    assert simulations[2].exit_code != 0
