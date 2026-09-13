# ruff: noqa: S101, SLF001

from __future__ import annotations

import io
import subprocess
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


def test_close_closes_standard_input() -> None:
    """Closing the wrapper should close queue input."""
    queue = _queue_without_init()
    queue._stdin = MagicMock()

    queue.close()

    queue._stdin.close.assert_called_once_with()


def test_close_suppresses_pipe_oserror() -> None:
    """An already-broken input pipe should not make close fail."""
    queue = _queue_without_init()
    queue._stdin = MagicMock()
    queue._stdin.close.side_effect = OSError("broken pipe")

    queue.close()

    queue._stdin.close.assert_called_once_with()


def test_wait_uses_process_context_and_returns_exit_code() -> None:
    """Waiting should delegate to Popen and leave pipe cleanup to its context manager."""
    queue = _queue_without_init()
    child = MagicMock()
    child.wait.return_value = 7
    queue._process = child

    assert queue.wait() == 7
    child.__enter__.assert_called_once_with()
    child.wait.assert_called_once_with()
    child.__exit__.assert_called_once_with(None, None, None)


def test_require_stream_returns_available_stream() -> None:
    """The configured stream helper should preserve a valid stream object."""
    stream = io.StringIO()

    assert process.QueueProcess._require_stream(stream, "stdin") is stream


def test_require_stream_rejects_none() -> None:
    """The configured stream helper should identify a missing stream."""
    with pytest.raises(RuntimeError, match="queue stdout is unavailable"):
        process.QueueProcess._require_stream(None, "stdout")
