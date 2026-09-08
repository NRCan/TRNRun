"""Synchronous queue lifecycle tests; no executable is ever launched."""

# ruff: noqa: S101
# pyright: reportUnusedCallResult=false, reportUnusedParameter=false

from __future__ import annotations

import json
from collections import deque
from pathlib import Path

import pytest

from trnrun.config import SimulationConfig
from trnrun.events import LogEvent, QueueEvent, StatusEvent
from trnrun.manager import SimulationManager
from trnrun.simulation import Simulation

TIMESTAMP = "2026-09-07T12:00:00Z"


class FakeQueueProcess:
    """Script queue output and record pipe lifecycle calls."""

    def __init__(self) -> None:
        """Start with an empty output script and a successful exit code."""
        self.lines: deque[str] = deque()
        self.requests: list[dict[str, object]] = []

        self.read_calls: int = 0
        self.close_calls: int = 0
        self.wait_calls: int = 0
        self.eof: bool = False

    def send(self, request: dict[str, object]) -> None:
        """Record a submission without running it."""
        assert not self.eof
        assert self.close_calls == 0
        self.requests.append(request)

    def read_line(self) -> str | None:
        """Return the next line, or EOF once the script is exhausted."""
        self.read_calls += 1
        if self.lines:
            return self.lines.popleft()
        self.eof = True
        return None

    def close(self) -> None:
        """Record closing the submission pipe."""
        self.close_calls += 1

    def wait(self) -> int:
        """Wait once during shutdown, after stdout has been drained."""
        assert self.close_calls == 1
        assert self.eof
        self.wait_calls += 1
        assert self.wait_calls == 1, "queue process was waited on more than once"
        return 0


def event_line(kind: str, run_id: str = "1", **fields: object) -> str:
    """Encode an event using the queue's merged stdout format."""
    return json.dumps({"kind": kind, "runId": run_id, "timestamp": TIMESTAMP, **fields}) + "\n"


@pytest.fixture
def queue(monkeypatch: pytest.MonkeyPatch) -> FakeQueueProcess:
    """Replace the manager's process constructor with a scripted fake."""
    process = FakeQueueProcess()

    def create_process(executable: str | Path, max_concurrent: int) -> FakeQueueProcess:
        assert Path(executable).is_file()
        assert max_concurrent == 2
        return process

    monkeypatch.setattr("trnrun.manager.QueueProcess", create_process)
    return process


@pytest.fixture
def inputs(tmp_path: Path) -> tuple[Path, SimulationConfig]:
    """Provide real files so submission exercises configuration validation."""
    deck = tmp_path / "test.dck"
    runner = tmp_path / "trnrun.exe"
    trnexe = tmp_path / "TrnEXE64.exe"
    for path in (deck, runner, trnexe):
        path.touch()
    return deck, SimulationConfig(trnrun_path=runner, trnexe_path=trnexe)


@pytest.fixture
def manager(queue: FakeQueueProcess, tmp_path: Path) -> SimulationManager:  # noqa: ARG001 - fixture dependency
    """Create a display-free manager after installing the fake process."""
    executable = tmp_path / "trnrunq.exe"
    executable.touch()
    return SimulationManager(max_concurrent=2, refresh_interval=0, trnrunq_path=executable)


@pytest.mark.parametrize("with_run", [False, True])
def test_clean_context_drains_and_waits_once(
    manager: SimulationManager,
    queue: FakeQueueProcess,
    inputs: tuple[Path, SimulationConfig],
    *,
    with_run: bool,
) -> None:
    """Shutdown closes input, drains output, and waits for the queue once."""
    with manager:
        if with_run:
            queue.lines.extend(
                [
                    event_line("QUEUE", event="ACCEPTED"),
                    event_line("STATUS", status="DONE"),
                    event_line("QUEUE", event="COMPLETED", exitCode=0),
                ],
            )
            simulation = manager.add(*inputs)
            assert simulation.is_accepted
            assert not simulation.is_finished
            assert queue.read_calls == 1
        assert queue.close_calls == 0

    assert all(simulation.succeeded for simulation in manager.simulations)
    assert len(manager.simulations) == int(with_run)
    assert queue.eof
    assert queue.read_calls == (4 if with_run else 1)
    assert (queue.close_calls, queue.wait_calls) == (1, 1)
    assert len(queue.requests) == int(with_run)


def test_wait_drains_runs_without_closing_queue_or_accepting_timeout(
    manager: SimulationManager,
    queue: FakeQueueProcess,
    inputs: tuple[Path, SimulationConfig],
) -> None:
    """Wait returns None and stops at completion, not at queue EOF."""
    assert manager.wait() is None
    with pytest.raises(TypeError):
        manager.wait(timeout=0)  # pyright: ignore[reportCallIssue]
    queue.lines.extend(
        [
            event_line("QUEUE", event="ACCEPTED"),
            event_line("STATUS", status="DONE"),
            event_line("QUEUE", event="COMPLETED", exitCode=0),
        ],
    )
    simulation = manager.add(*inputs)
    assert manager.wait() is None
    assert simulation.succeeded
    assert queue.read_calls == 3
    assert (queue.close_calls, queue.wait_calls) == (0, 0)
    manager.shutdown()


def test_failed_send_leaves_no_active_run_and_does_not_reuse_id(
    manager: SimulationManager,
    queue: FakeQueueProcess,
    inputs: tuple[Path, SimulationConfig],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A failed send needs no rollback, and the next request has a fresh id."""

    def fail_send(_request: dict[str, object]) -> None:
        raise OSError("send failed")

    with manager:
        with monkeypatch.context() as patch:
            patch.setattr(queue, "send", fail_send)
            with pytest.raises(OSError, match="send failed"):
                manager.add(*inputs)
        assert manager.simulations == []
        manager.wait()
        assert queue.read_calls == 0

        queue.lines.extend(
            [
                event_line("QUEUE", "2", event="ACCEPTED"),
                event_line("STATUS", "2", status="DONE"),
                event_line("QUEUE", "2", event="COMPLETED", exitCode=0),
            ],
        )
        simulation = manager.add(*inputs)
        assert simulation.id == 2
        assert simulation.is_accepted
        assert manager.simulations == [simulation]

    assert simulation.succeeded
    assert [request["runId"] for request in queue.requests] == ["2"]
    assert (queue.close_calls, queue.wait_calls) == (1, 1)


def test_eof_before_acceptance_rejects_submission(
    manager: SimulationManager,
    queue: FakeQueueProcess,
    inputs: tuple[Path, SimulationConfig],
) -> None:
    """EOF stops acceptance without hanging, and context exit closes the process."""
    with pytest.raises(RuntimeError, match="before accepting"), manager:
        manager.add(*inputs)
    assert manager.simulations == []
    assert len(queue.requests) == 1
    assert (queue.read_calls, queue.close_calls, queue.wait_calls) == (2, 1, 1)


@pytest.mark.parametrize(
    ("status", "exit_code", "succeeded"),
    [
        pytest.param("DONE", 0, True, id="success"),
        pytest.param("DONE", 9, True, id="done-with-nonzero-exit"),
        pytest.param("ERROR", 0, False, id="error-with-zero-exit"),
        pytest.param(None, None, False, id="null-launch-failure"),
        pytest.param(None, 11, False, id="silent-crash"),
    ],
)
def test_completion_retains_metadata_without_defining_success(
    manager: SimulationManager,
    queue: FakeQueueProcess,
    inputs: tuple[Path, SimulationConfig],
    status: str | None,
    exit_code: int | None,
    *,
    succeeded: bool,
) -> None:
    """Completion metadata is distinct from the runner status defining success."""
    queue.lines.append(event_line("QUEUE", event="ACCEPTED"))
    simulation = manager.add(*inputs)
    updates = manager.follow()
    if status is not None:
        queue.lines.append(event_line("STATUS", status=status))
        assert next(updates) is simulation
        assert not simulation.succeeded
    queue.lines.append(event_line("QUEUE", event="COMPLETED", exitCode=exit_code))
    assert list(updates) == [simulation]
    assert simulation.completion_event == QueueEvent("COMPLETED", "1", TIMESTAMP, exit_code)
    assert simulation.is_finished
    assert simulation.succeeded == succeeded
    assert (simulation.status is None) == (status is None)
    manager.shutdown()


def test_interleaved_add_and_follow_do_not_replay_consumed_updates(
    manager: SimulationManager,
    queue: FakeQueueProcess,
    inputs: tuple[Path, SimulationConfig],
) -> None:
    """Add advances other runs while a follow iterator is suspended."""
    queue.lines.extend(
        [
            event_line("QUEUE", event="ACCEPTED"),
            event_line("STATUS", status="RUNNING"),
            event_line("LOG", severity="warning", message="during second add"),
            event_line("STATUS", status="DONE"),
            event_line("QUEUE", "2", event="ACCEPTED"),
            event_line("QUEUE", event="COMPLETED", exitCode=0),
            event_line("STATUS", "2", status="DONE"),
            event_line("QUEUE", "2", event="COMPLETED", exitCode=0),
        ],
    )
    first = manager.add(*inputs)
    updates = manager.follow()
    assert next(updates) is first
    assert first.status == StatusEvent("RUNNING", TIMESTAMP)
    second = manager.add(*inputs)
    assert first.status == StatusEvent("DONE", TIMESTAMP)
    assert first.warnings == 1
    assert not first.is_finished
    assert second.status is None
    assert queue.read_calls == 5
    snapshots = [(sim.id, sim.is_finished) for sim in updates]
    assert snapshots == [(first.id, True), (second.id, False), (second.id, True)]
    assert manager.simulations == [first, second]
    reads = queue.read_calls
    assert list(manager.follow()) == []
    assert manager.wait() is None
    assert queue.read_calls == reads
    manager.shutdown()


def test_malformed_unknown_and_late_events_do_not_change_completed_run(
    manager: SimulationManager,
    queue: FakeQueueProcess,
    inputs: tuple[Path, SimulationConfig],
) -> None:
    """Drain ignores bad framing, unknown ids, and output from retired runs."""
    queue.lines.extend(
        [
            "\n",
            "runner diagnostic\n",
            '{"kind":"STATUS","runId":"1"}\n',
            event_line("STATUS", "unknown", status="ERROR"),
            event_line("QUEUE", event="ACCEPTED"),
            event_line("QUEUE", event="ACCEPTED"),
            event_line("QUEUE", event="UNKNOWN"),
            event_line("STATUS", status="DONE"),
            event_line("QUEUE", event="COMPLETED", exitCode=0),
            event_line("QUEUE", event="COMPLETED", exitCode=99),
            event_line("QUEUE", event="ACCEPTED"),
            event_line("STATUS", status="ERROR"),
            event_line("LOG", severity="fatal", message="late output"),
        ],
    )
    with manager:
        simulation = manager.add(*inputs)
        assert [updated.is_finished for updated in manager.follow()] == [False, True]
    assert manager.simulations == [simulation]
    assert simulation.status == StatusEvent("DONE", TIMESTAMP)
    assert simulation.completion_event == QueueEvent("COMPLETED", "1", TIMESTAMP, 0)
    assert simulation.logs == []
    assert simulation.log_count == 0
    assert simulation.succeeded
    assert not queue.lines


def test_mark_completed_keeps_first_completion_and_is_read_only(
    inputs: tuple[Path, SimulationConfig],
) -> None:
    """Neither repeated completion nor late runner events rewrite final state."""
    simulation = Simulation(*inputs, sim_id=1)
    status = StatusEvent("DONE", TIMESTAMP)
    simulation.apply_event(status)
    assert not simulation.succeeded
    assert simulation.completion_event is None
    assert not simulation.is_finished
    completion = QueueEvent("COMPLETED", "1", TIMESTAMP, 0)
    simulation.mark_completed(completion)
    simulation.mark_completed(QueueEvent("COMPLETED", "1", "later", 99))
    simulation.apply_event(StatusEvent("ERROR", "later"))
    simulation.apply_event(LogEvent("fatal", "later", message="late output"))
    assert simulation.completion_event is completion
    assert simulation.is_finished
    assert simulation.status is status
    assert simulation.logs == []
    assert simulation.succeeded
    with pytest.raises(AttributeError):
        simulation.completion_event = completion  # pyright: ignore[reportAttributeAccessIssue]
