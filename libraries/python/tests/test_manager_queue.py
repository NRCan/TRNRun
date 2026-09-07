"""Tests for the Python manager's TRNRun Queue protocol handling."""

# ruff: noqa: S101

from __future__ import annotations

import json
import queue
import threading
from collections.abc import Iterator
from pathlib import Path
from typing import cast, final
from unittest.mock import patch

from trnrun.config import SimulationConfig
from trnrun.manager import SimulationManager
from trnrun.simulation import Simulation

TIMESTAMP = "2026-09-06T12:34:56"


@final
class _FakeOutput:
    """Blocking line iterator controlled by a fake queue process."""

    def __init__(self) -> None:
        self._lines: queue.Queue[str | None] = queue.Queue()

    def __iter__(self) -> Iterator[str]:
        while True:
            line = self._lines.get()
            if line is None:
                return
            yield line

    def emit(self, payload: dict[str, object]) -> None:
        """Queue one JSON event for the manager reader."""
        self._lines.put(json.dumps(payload) + "\n")

    def finish(self) -> None:
        """End the output stream."""
        self._lines.put(None)


@final
class _FakeInput:
    """Capture JSON request lines written by the manager."""

    def __init__(self, process: _FakeProcess) -> None:
        self._process: _FakeProcess = process
        self._buffer: str = ""
        self.closed: bool = False

    def write(self, value: str) -> int:
        """Capture complete request lines."""
        if self.closed:
            raise ValueError("I/O operation on closed queue stdin")

        self._buffer += value
        while "\n" in self._buffer:
            line, self._buffer = self._buffer.split("\n", 1)
            if line:
                payload = cast("object", json.loads(line))
                if isinstance(payload, dict):
                    self._process.requests.put(cast("dict[str, object]", payload))
        return len(value)

    def flush(self) -> None:
        """Accept writes immediately."""

    def close(self) -> None:
        """Signal normal queue shutdown."""
        self.closed = True
        self._process.finish(0)


@final
class _FakeProcess:
    """Minimal interactive `Popen` replacement for queue tests."""

    def __init__(self) -> None:
        self.requests: queue.Queue[dict[str, object]] = queue.Queue()
        self.stdout: _FakeOutput = _FakeOutput()
        self.stdin: _FakeInput = _FakeInput(self)
        self._exited: threading.Event = threading.Event()
        self._exit_code: int | None = None

    def emit(self, payload: dict[str, object]) -> None:
        """Emit one queue or runner event."""
        self.stdout.emit(payload)

    def finish(self, exit_code: int) -> None:
        """Exit once and close stdout."""
        if self._exit_code is not None:
            return
        self._exit_code = exit_code
        self._exited.set()
        self.stdout.finish()

    @property
    def exited(self) -> bool:
        """Return whether the fake queue has exited."""
        return self._exited.is_set()

    def wait(self, timeout: float | None = None) -> int:
        """Wait for the fake process to exit."""
        if not self._exited.wait(timeout):
            raise TimeoutError("fake queue did not exit")
        if self._exit_code is None:
            raise RuntimeError("fake queue exit code unavailable")
        return self._exit_code


def _create_inputs(tmp_path: Path) -> tuple[Path, Path, SimulationConfig]:
    queue_path = tmp_path / "trnrunq.exe"
    runner_path = tmp_path / "trnrun.exe"
    trnexe_path = tmp_path / "TrnEXE64.exe"
    deck_path = tmp_path / "example.dck"
    for path in (queue_path, runner_path, trnexe_path, deck_path):
        path.touch()

    return queue_path, deck_path, SimulationConfig(
        trnrun_path=runner_path,
        trnexe_path=trnexe_path,
    )


def test_add_waits_for_acceptance_while_reader_routes_runner_events(tmp_path: Path) -> None:
    """Only QUEUE/ACCEPTED unblocks add, regardless of stdout event order."""
    queue_path, deck_path, config = _create_inputs(tmp_path)
    process = _FakeProcess()

    with (
        patch("trnrun.manager.subprocess.Popen", return_value=process),
        patch("trnrun.manager.assign_to_job") as assign_to_job,
    ):
        manager = SimulationManager(
            max_concurrent=1,
            max_pending=1,
            refresh_interval=0,
            trnrunq_path=queue_path,
        )

    assign_to_job.assert_called_once_with(process)
    result: list[Simulation] = []
    submitter = threading.Thread(target=lambda: result.append(manager.add(deck_path, config)))
    submitter.start()

    request = process.requests.get(timeout=1)
    assert request["runId"] == "1"
    assert request["deckFile"] == str(deck_path)
    assert request["runnerPath"] == str(config.trnrun_path)

    assert manager.simulations == []
    process.emit(
        {
            "kind": "STATUS",
            "timestamp": TIMESTAMP,
            "status": "RUNNING",
            "runId": "1",
        },
    )
    assert submitter.is_alive()

    process.emit(
        {
            "kind": "QUEUE",
            "timestamp": TIMESTAMP,
            "event": "ACCEPTED",
            "runId": "1",
        },
    )
    submitter.join(timeout=1)
    assert not submitter.is_alive()
    simulation = result[0]
    assert manager.simulations == [simulation]
    assert simulation.status is not None
    assert simulation.status.status == "RUNNING"

    process.emit(
        {
            "kind": "STATUS",
            "timestamp": TIMESTAMP,
            "status": "DONE",
            "message": "simulation completed",
            "runId": "1",
        },
    )
    process.emit(
        {
            "kind": "LOG",
            "timestamp": TIMESTAMP,
            "severity": "Warning",
            "message": "cleanup warning after terminal status",
            "runId": "1",
        },
    )
    assert not manager.wait(timeout=0)
    process.emit(
        {
            "kind": "QUEUE",
            "timestamp": TIMESTAMP,
            "event": "COMPLETED",
            "runId": "1",
            "exitCode": 0,
        },
    )
    assert manager.wait(timeout=1)
    assert simulation.status is not None
    assert simulation.status.message == "simulation completed"
    assert len(simulation.logs) == 1
    assert simulation.logs[0].message == "cleanup warning after terminal status"
    manager.shutdown()


def test_completed_without_terminal_status_fails_before_queue_eof(tmp_path: Path) -> None:
    """A silent or crashed runner fails without waiting for queue shutdown."""
    queue_path, deck_path, config = _create_inputs(tmp_path)
    process = _FakeProcess()

    with (
        patch("trnrun.manager.subprocess.Popen", return_value=process),
        patch("trnrun.manager.assign_to_job"),
    ):
        manager = SimulationManager(refresh_interval=0, trnrunq_path=queue_path)

    result: list[Simulation] = []
    submitter = threading.Thread(target=lambda: result.append(manager.add(deck_path, config)))
    submitter.start()
    _ = process.requests.get(timeout=1)
    process.emit(
        {
            "kind": "QUEUE",
            "timestamp": TIMESTAMP,
            "event": "ACCEPTED",
            "runId": "1",
        },
    )
    submitter.join(timeout=1)
    assert not submitter.is_alive()

    simulation = result[0]
    process.emit(
        {
            "kind": "STATUS",
            "timestamp": TIMESTAMP,
            "status": "RUNNING",
            "runId": "1",
        },
    )
    process.emit(
        {
            "kind": "STATUS",
            "timestamp": TIMESTAMP,
            "status": "done",
            "runId": "1",
        },
    )
    process.emit(
        {
            "kind": "QUEUE",
            "timestamp": TIMESTAMP,
            "event": "COMPLETED",
            "runId": "1",
            "exitCode": 2,
        },
    )

    assert simulation.wait(timeout=1)
    assert not process.exited
    assert simulation.status is not None
    assert simulation.status.status == "ERROR"
    assert simulation.status.message == "TRNRun exited with code 2 without a terminal STATUS event"
    assert manager.failed == [simulation]
    manager.shutdown()



def test_queue_eof_before_completion_overrides_a_terminal_status(tmp_path: Path) -> None:
    """Queue exit before COMPLETED makes even a terminal run fail closed."""
    queue_path, deck_path, config = _create_inputs(tmp_path)
    process = _FakeProcess()

    with (
        patch("trnrun.manager.subprocess.Popen", return_value=process),
        patch("trnrun.manager.assign_to_job"),
    ):
        manager = SimulationManager(refresh_interval=0, trnrunq_path=queue_path)

    result: list[Simulation] = []
    submitter = threading.Thread(target=lambda: result.append(manager.add(deck_path, config)))
    submitter.start()
    _ = process.requests.get(timeout=1)
    process.emit(
        {
            "kind": "QUEUE",
            "timestamp": TIMESTAMP,
            "event": "ACCEPTED",
            "runId": "1",
        },
    )
    submitter.join(timeout=1)
    assert not submitter.is_alive()

    process.emit(
        {
            "kind": "STATUS",
            "timestamp": TIMESTAMP,
            "status": "DONE",
            "runId": "1",
        },
    )
    process.finish(1)
    simulation = result[0]
    assert simulation.wait(timeout=1)
    status = simulation.status
    assert status is not None
    assert status.status == "ERROR"
    assert status.message == "TRNRun queue exited with code 1"
    manager.shutdown()


def test_queue_eof_fails_a_submission_waiting_for_acceptance(tmp_path: Path) -> None:
    """Queue termination releases acceptance waiters instead of hanging add."""
    queue_path, deck_path, config = _create_inputs(tmp_path)
    process = _FakeProcess()

    with (
        patch("trnrun.manager.subprocess.Popen", return_value=process),
        patch("trnrun.manager.assign_to_job"),
    ):
        manager = SimulationManager(refresh_interval=0, trnrunq_path=queue_path)

    errors: list[RuntimeError] = []

    def submit() -> None:
        try:
            _ = manager.add(deck_path, config)
        except RuntimeError as error:
            errors.append(error)

    submitter = threading.Thread(target=submit)
    submitter.start()
    _ = process.requests.get(timeout=1)

    process.finish(2)
    submitter.join(timeout=1)

    assert not submitter.is_alive()
    assert len(errors) == 1
    assert isinstance(errors[0], RuntimeError)
    assert "exited with code 2 before accepting simulation 1" in str(errors[0])
    assert manager.simulations == []
    manager.shutdown()
