# ruff: noqa: S101, SLF001

from __future__ import annotations

import io
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import MagicMock, Mock, call

import pytest

from trnrun import process


def _create_executable(tmp_path: Path) -> Path:
    """Create a harmless file that satisfies the constructor's path check."""
    executable = tmp_path / "trnrunq.exe"
    executable.touch()
    return executable


def _queue_without_init() -> process.QueueProcess:
    """Allocate a queue wrapper without spawning its process."""
    return object.__new__(process.QueueProcess)


@pytest.mark.parametrize("max_concurrent", [0, -1])
def test_init_rejects_nonpositive_concurrency(
    monkeypatch: pytest.MonkeyPatch,
    max_concurrent: int,
) -> None:
    """Invalid concurrency should fail before checking paths or spawning."""
    popen = Mock()
    monkeypatch.setattr(process.subprocess, "Popen", popen)

    with pytest.raises(ValueError, match="max_concurrent must be at least 1"):
        process.QueueProcess("does-not-matter.exe", max_concurrent)

    popen.assert_not_called()


def test_init_rejects_missing_executable(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """A missing executable should produce a useful error without spawning."""
    popen = Mock()
    missing = tmp_path / "missing.exe"
    monkeypatch.setattr(process.subprocess, "Popen", popen)

    with pytest.raises(FileNotFoundError, match=r"TRNRun queue executable not found: .*missing\.exe"):
        process.QueueProcess(missing, 1)

    popen.assert_not_called()


def test_init_spawns_configured_process_and_assigns_job(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Construction should configure text pipes and adopt the child process."""
    executable = _create_executable(tmp_path)
    child = SimpleNamespace(stdin=io.StringIO(), stdout=io.StringIO())
    popen = Mock(return_value=child)
    assign_to_job = Mock(return_value=True)
    monkeypatch.setattr(process.subprocess, "Popen", popen)
    monkeypatch.setattr(process, "assign_to_job", assign_to_job)

    queue = process.QueueProcess(executable, 3)

    popen.assert_called_once_with(
        [str(executable.absolute()), "--maxConcurrent:3"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        encoding="utf-8",
        errors="replace",
        creationflags=process.CREATE_NO_WINDOW,
    )
    assign_to_job.assert_called_once_with(child)
    assert queue._process is child
    assert queue._stdin is child.stdin
    assert queue._stdout is child.stdout


@pytest.mark.parametrize(
    ("stdin", "stdout", "missing_name"),
    [
        pytest.param(None, io.StringIO(), "stdin", id="stdin"),
        pytest.param(io.StringIO(), None, "stdout", id="stdout"),
    ],
)
def test_init_rejects_unavailable_pipe(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    stdin: io.StringIO | None,
    stdout: io.StringIO | None,
    missing_name: str,
) -> None:
    """Construction should fail clearly if Popen does not provide a requested pipe."""
    executable = _create_executable(tmp_path)
    child = SimpleNamespace(stdin=stdin, stdout=stdout)
    monkeypatch.setattr(process.subprocess, "Popen", Mock(return_value=child))
    monkeypatch.setattr(process, "assign_to_job", Mock(return_value=True))

    with pytest.raises(RuntimeError, match=rf"queue {missing_name} is unavailable"):
        process.QueueProcess(executable, 1)


def test_send_writes_compact_json_line_and_flushes() -> None:
    """Requests should use the queue's compact, one-line JSON framing."""
    queue = _queue_without_init()
    stream = MagicMock()
    queue._stdin = stream

    queue.send({"name": "a b", "values": [True, None, 2]})

    assert stream.mock_calls == [
        call.write('{"name":"a b","values":[true,null,2]}\n'),
        call.flush(),
    ]


def test_send_rejects_nonstandard_nan_without_writing() -> None:
    """Non-standard JSON numbers should be rejected before touching the pipe."""
    queue = _queue_without_init()
    stream = MagicMock()
    queue._stdin = stream

    with pytest.raises(ValueError, match="Out of range float values are not JSON compliant"):
        queue.send({"value": float("nan")})

    stream.write.assert_not_called()
    stream.flush.assert_not_called()


@pytest.mark.parametrize(
    ("raw_line", "expected"),
    [
        pytest.param('{"event":"started"}\n', '{"event":"started"}\n', id="line"),
        pytest.param("", None, id="eof"),
    ],
)
def test_read_line_returns_lines_and_none_at_eof(raw_line: str, expected: str | None) -> None:
    """Queue output should remain unmodified while EOF receives a sentinel."""
    queue = _queue_without_init()
    queue._stdout = io.StringIO(raw_line)

    assert queue.read_line() == expected


def test_shutdown_kills_before_waiting_and_closing_pipes() -> None:
    """Shutdown must not wait for or drain a queue that could have full stdout."""
    queue = _queue_without_init()
    child = MagicMock()
    child.wait.return_value = 7
    queue._process = child
    queue._stdin = child.stdin
    queue._stdout = child.stdout

    assert queue.shutdown() is None

    assert child.mock_calls == [call.kill(), call.wait(), call.stdin.close(), call.stdout.close()]


@pytest.mark.parametrize("exit_code", [0, 7])
def test_shutdown_handles_already_exited_process(exit_code: int) -> None:
    """An exited child still needs pipe cleanup, regardless of its exit code."""
    with subprocess.Popen(
        [sys.executable, "-c", f"raise SystemExit({exit_code})"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        text=True,
        encoding="utf-8",
    ) as child:
        assert child.stdin is not None
        assert child.stdout is not None
        queue = _queue_without_init()
        queue._process = child
        queue._stdin = child.stdin
        queue._stdout = child.stdout
        assert child.wait(timeout=10) == exit_code

        assert queue.shutdown() is None

        assert child.returncode == exit_code
        assert child.stdin.closed
        assert child.stdout.closed


@pytest.mark.parametrize("pipe_name", ["stdin", "stdout"])
def test_shutdown_suppresses_pipe_oserror(pipe_name: str) -> None:
    """A broken pipe should not prevent reaping or closing the other pipe."""
    queue = _queue_without_init()
    child = MagicMock()
    queue._process = child
    queue._stdin = child.stdin
    queue._stdout = child.stdout
    getattr(child, pipe_name).close.side_effect = BrokenPipeError("broken pipe")

    assert queue.shutdown() is None

    assert child.mock_calls == [call.kill(), call.wait(), call.stdin.close(), call.stdout.close()]


@pytest.mark.parametrize("operation", ["kill", "wait"])
@pytest.mark.parametrize("error_type", [OSError, KeyboardInterrupt])
def test_shutdown_closes_pipes_after_process_error(
    operation: str,
    error_type: type[BaseException],
) -> None:
    """Process failures and interruptions should propagate after pipe cleanup."""
    queue = _queue_without_init()
    child = MagicMock()
    queue._process = child
    queue._stdin = child.stdin
    queue._stdout = child.stdout
    error = error_type("process interrupted")
    getattr(child, operation).side_effect = error
    child.stdin.close.side_effect = BrokenPipeError("broken pipe")

    with pytest.raises(error_type) as raised:
        queue.shutdown()

    assert raised.value is error
    expected = [call.kill()]
    if operation == "wait":
        expected.append(call.wait())
    assert child.mock_calls == [*expected, call.stdin.close(), call.stdout.close()]


def test_require_stream_returns_available_stream() -> None:
    """The configured stream helper should preserve a valid stream object."""
    stream = io.StringIO()

    assert process.QueueProcess._require_stream(stream, "stdin") is stream


def test_require_stream_rejects_none() -> None:
    """The configured stream helper should identify a missing stream."""
    with pytest.raises(RuntimeError, match="queue stdout is unavailable"):
        process.QueueProcess._require_stream(None, "stdout")
