# ruff: noqa: S101, SLF001

from __future__ import annotations

import io
import subprocess
import sys
import threading
from collections.abc import Callable, Iterator
from contextlib import nullcontext
from dataclasses import dataclass
from pathlib import Path
from threading import Event, Lock, Thread, current_thread
from typing import IO, override
from unittest.mock import MagicMock, Mock, call

import pytest

from trnrun import process

TEST_TIMEOUT = 10.0


class BlockingOutput(io.StringIO):
    """Deliver buffered lines, then wait for an explicitly signalled EOF."""

    def __init__(self, text: str = "") -> None:
        """Create an output pipe controlled by Events rather than timing."""
        super().__init__(text)
        self.reading: Event = Event()
        self.eof: Event = Event()
        self.closed_by: Thread | None = None

    @override
    def readline(self, size: int = -1) -> str:
        """Block at EOF until the test or fake child releases the reader."""
        line = super().readline(size)
        if not line:
            self.reading.set()
            assert self.eof.wait(TEST_TIMEOUT), "test did not release stdout"
        return line

    @override
    def close(self) -> None:
        """Record which thread actually closes the pipe."""
        self.closed_by = current_thread()
        super().close()


@dataclass
class Harness:
    """A real reader thread backed by controlled child-process boundaries."""

    queue: process.QueueProcess
    child: Mock
    popen: Mock
    output: Mock


@pytest.fixture
def make_queue(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> Iterator[Callable[..., Harness]]:
    """Build queues and ensure no reader is left behind by a test."""
    queues: list[Harness] = []
    executable = tmp_path / "trnrunq.exe"
    executable.touch()
    monkeypatch.setattr(process, "assign_to_job", Mock(return_value=True))

    def create(
        stdin: IO[str] | None = None,
        stdout: IO[str] | None = None,
        on_output: Callable[[str], None] | None = None,
        on_exit: Callable[[], None] | None = None,
    ) -> Harness:
        output = Mock(side_effect=on_output)
        child = Mock(stdin=stdin if stdin is not None else io.StringIO())
        child.stdout = stdout if stdout is not None else BlockingOutput()
        if isinstance(child.stdout, BlockingOutput):
            child.kill.side_effect = child.stdout.eof.set
        child.poll.return_value = None

        def wait(*, timeout: float) -> int:
            assert timeout == process.SHUTDOWN_TIMEOUT
            child.poll.return_value = 0
            return 0

        child.wait.side_effect = wait
        popen = Mock(return_value=child)
        monkeypatch.setattr(process.subprocess, "Popen", popen)

        queue = process.QueueProcess(executable, 3, output, on_exit)
        harness = Harness(queue, child, popen, output)
        queues.append(harness)
        return harness

    yield create

    for harness in queues:
        if isinstance(harness.child.stdout, BlockingOutput):
            harness.child.stdout.eof.set()
        harness.queue.shutdown()
        assert not harness.queue._reader.is_alive()


def _start(action: Callable[[], None]) -> tuple[Thread, list[Exception]]:
    """Run an operation in a worker while retaining its actual exception."""
    errors: list[Exception] = []

    def run() -> None:
        try:
            action()
        except Exception as exc:  # noqa: BLE001 - inspect worker failures in the test thread
            errors.append(exc)

    thread = Thread(target=run, daemon=True)
    thread.start()
    return thread, errors


def _join(thread: Thread) -> None:
    """Bound every test wait, so a regression fails instead of hanging pytest."""
    thread.join(TEST_TIMEOUT)
    assert not thread.is_alive(), "worker did not finish"


@pytest.mark.parametrize("max_concurrent", [0, -1, True, False, 1.0, 1.5, float("nan"), float("inf"), "2", None])
def test_init_rejects_invalid_concurrency(monkeypatch: pytest.MonkeyPatch, max_concurrent: int) -> None:
    """Invalid concurrency should fail before checking paths or spawning."""
    popen = Mock()
    monkeypatch.setattr(process.subprocess, "Popen", popen)

    with pytest.raises(ValueError, match="max_concurrent must be an integer of at least 1"):
        process.QueueProcess("does-not-matter.exe", max_concurrent, Mock())

    popen.assert_not_called()


def test_init_rejects_missing_executable(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """A missing executable should fail without spawning."""
    popen = Mock()
    monkeypatch.setattr(process.subprocess, "Popen", popen)

    with pytest.raises(FileNotFoundError, match=r"TRNRun queue executable not found: .*missing\.exe"):
        process.QueueProcess(tmp_path / "missing.exe", 1, Mock())

    popen.assert_not_called()


def test_init_spawns_configured_process_and_assigns_job(
    make_queue: Callable[..., Harness],
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    """Construction configures text pipes and starts a background reader."""
    assign = Mock(return_value=True)
    monkeypatch.setattr(process, "assign_to_job", assign)
    harness = make_queue()

    harness.popen.assert_called_once_with(
        [str((tmp_path / "trnrunq.exe").absolute()), "--maxConcurrent:3"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        encoding="utf-8",
        errors="replace",
        creationflags=process.CREATE_NO_WINDOW,
    )
    assign.assert_called_once_with(harness.child)
    assert harness.child.stdout.reading.wait(TEST_TIMEOUT)
    assert harness.queue._reader.is_alive()
    assert harness.queue._reader.daemon


@pytest.mark.parametrize("failure", ["spawn", "job", "stdin", "stdout", "thread", "start"])
def test_init_failure_releases_acquired_resources(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    failure: str,
) -> None:
    """Startup failures preserve their cause and release every acquired resource."""
    executable = tmp_path / "trnrunq.exe"
    executable.touch()
    child = Mock(stdin=io.StringIO(), stdout=io.StringIO())
    output = Mock()
    error = RuntimeError("startup failed")
    popen = Mock(return_value=child)
    assign = Mock(return_value=True)
    monkeypatch.setattr(process.subprocess, "Popen", popen)
    monkeypatch.setattr(process, "assign_to_job", assign)
    if failure == "spawn":
        popen.side_effect = error
    elif failure == "job":
        assign.side_effect = error
    elif failure in {"stdin", "stdout"}:
        getattr(child, failure).close()
        setattr(child, failure, None)
    elif failure == "thread":
        monkeypatch.setattr(process, "Thread", Mock(side_effect=error))
    else:
        monkeypatch.setattr(process.Thread, "start", Mock(side_effect=error))

    with pytest.raises(RuntimeError) as caught:
        process.QueueProcess(executable, 1, output)

    if failure in {"stdin", "stdout"}:
        assert str(caught.value) == "TRNRun queue pipes are unavailable"
    else:
        assert caught.value is error
    if failure == "spawn":
        child.kill.assert_not_called()
        child.wait.assert_not_called()
        child.stdin.close()
        child.stdout.close()
    else:
        child.kill.assert_called_once_with()
        child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
        assert child.stdin is None or child.stdin.closed
        assert child.stdout is None or child.stdout.closed
    output.assert_not_called()


def test_startup_cleanup_preserves_original_exception(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """A cleanup failure must not hide the constructor's actual failure."""
    executable = tmp_path / "trnrunq.exe"
    executable.touch()
    child = Mock(stdin=io.StringIO(), stdout=io.StringIO())
    child.kill.side_effect = OSError("kill failed")
    child.wait.side_effect = subprocess.TimeoutExpired("queue", 5)
    original = RuntimeError("job failed")
    monkeypatch.setattr(process.subprocess, "Popen", Mock(return_value=child))
    monkeypatch.setattr(process, "assign_to_job", Mock(side_effect=original))

    with pytest.raises(RuntimeError) as caught:
        process.QueueProcess(executable, 1, Mock())

    assert caught.value is original
    child.wait.assert_called_once()
    assert child.stdin.closed
    assert child.stdout.closed


def test_reader_delivers_lines_in_order_and_closes_at_eof(make_queue: Callable[..., Harness]) -> None:
    """Output is delivered continuously, unchanged, on one background thread."""
    threads: list[Thread] = []
    exited = Mock()
    harness = make_queue(
        stdout=io.StringIO('first\n\n{"event":"started"}\nlast'),
        on_output=lambda _line: threads.append(current_thread()),
        on_exit=exited,
    )
    _join(harness.queue._reader)

    assert harness.output.call_args_list == [call("first\n"), call("\n"), call('{"event":"started"}\n'), call("last")]
    assert threads == [harness.queue._reader] * 4
    assert harness.child.stdout.closed
    exited.assert_called_once_with()
    assert harness.queue._closing.is_set()
    assert harness.queue.is_alive
    with pytest.raises(RuntimeError, match="Cannot send after queue closure"):
        harness.queue.send({})


@pytest.mark.parametrize("failure", ["read", "output", "close"])
def test_reader_failure_closes_queue_and_reaches_thread_excepthook(
    make_queue: Callable[..., Harness],
    monkeypatch: pytest.MonkeyPatch,
    failure: str,
) -> None:
    """Reader failures escape the thread after cleanup, not through shutdown."""
    errors: list[threading.ExceptHookArgs] = []
    monkeypatch.setattr(threading, "excepthook", errors.append)
    error = ValueError("reader failed")
    stdout = Mock()
    stdout.readline.side_effect = ["one\n", "two\n", ""]
    if failure == "read":
        stdout.readline.side_effect = error
    elif failure == "close":
        stdout.close.side_effect = error
    output = Mock(side_effect=error if failure == "output" else None)
    exited = Mock()
    harness = make_queue(stdout=stdout, on_output=output, on_exit=exited)
    _join(harness.queue._reader)

    exited.assert_called_once_with()
    assert len(errors) == 1
    assert errors[0].exc_value is error
    assert errors[0].thread is harness.queue._reader
    assert harness.queue._closing.is_set()
    stdout.close.assert_called_once_with()
    harness.queue.shutdown()
    assert harness.child.stdin.closed
    if failure == "output":
        output.assert_called_once_with("one\n")


def test_send_writes_compact_json_line_and_flushes(make_queue: Callable[..., Harness]) -> None:
    """Requests use compact, strict, one-line JSON framing."""
    stream = MagicMock()
    harness = make_queue(stdin=stream)

    harness.queue.send({"name": "a b", "values": [True, None, 2]})

    assert stream.mock_calls == [call.write('{"name":"a b","values":[true,null,2]}\n'), call.flush()]


def test_send_rejects_nonstandard_nan_without_writing(make_queue: Callable[..., Harness]) -> None:
    """Invalid JSON numbers fail before any pipe access."""
    stream = MagicMock()
    harness = make_queue(stdin=stream)

    with pytest.raises(ValueError, match="Out of range float values are not JSON compliant"):
        harness.queue.send({"value": float("nan")})

    stream.write.assert_not_called()
    stream.flush.assert_not_called()


def test_concurrent_sends_serialize_write_and_flush(make_queue: Callable[..., Harness]) -> None:
    """A second sender cannot write until the first sender's flush completes."""
    flushing, release, attempting = Event(), Event(), Event()
    stream = Mock()
    harness = make_queue(stdin=stream)
    lock = Lock()
    observed = MagicMock()

    def enter() -> None:
        attempting.set()
        lock.acquire()

    observed.__enter__.side_effect = enter
    observed.__exit__.side_effect = lambda *_args: lock.release()
    harness.queue._write_lock = observed

    def flush() -> None:
        flushing.set()
        assert release.wait(TEST_TIMEOUT)

    stream.flush.side_effect = flush
    first, first_errors = _start(lambda: harness.queue.send({"id": 1}))
    second: Thread | None = None
    try:
        assert flushing.wait(TEST_TIMEOUT)
        attempting.clear()
        second, second_errors = _start(lambda: harness.queue.send({"id": 2}))
        assert attempting.wait(TEST_TIMEOUT)
        stream.write.assert_called_once_with('{"id":1}\n')
    finally:
        release.set()
        _join(first)
        if second is not None:
            _join(second)
        harness.queue._write_lock = lock

    assert not first_errors
    assert not second_errors
    assert stream.mock_calls == [call.write('{"id":1}\n'), call.flush(), call.write('{"id":2}\n'), call.flush()]


@pytest.mark.parametrize("failure", ["write", "flush"])
def test_send_failure_releases_write_lock(make_queue: Callable[..., Harness], failure: str) -> None:
    """Pipe failures propagate unchanged without stranding the write lock."""
    stream = Mock()
    error = BrokenPipeError("queue exited")
    getattr(stream, failure).side_effect = error
    harness = make_queue(stdin=stream)

    with pytest.raises(BrokenPipeError) as caught:
        harness.queue.send({})

    assert caught.value is error
    harness.queue.shutdown()
    stream.close.assert_called_once_with()


def test_shutdown_repeats_wait_and_close_with_stdout_owned_by_reader(make_queue: Callable[..., Harness]) -> None:
    """Sequential shutdowns reap every time, killing only a running child."""
    stdout = BlockingOutput()
    stdin = Mock()
    harness = make_queue(stdin=stdin, stdout=stdout)
    assert stdout.reading.wait(TEST_TIMEOUT)
    operations = Mock()
    operations.attach_mock(harness.child.poll, "poll")
    operations.attach_mock(harness.child.kill, "kill")
    operations.attach_mock(harness.child.wait, "wait")
    operations.attach_mock(stdin.close, "close")

    harness.queue.shutdown()
    harness.queue.shutdown()

    assert operations.mock_calls == [
        call.poll(),
        call.kill(),
        call.wait(timeout=process.SHUTDOWN_TIMEOUT),
        call.close(),
        call.poll(),
        call.wait(timeout=process.SHUTDOWN_TIMEOUT),
        call.close(),
    ]
    assert stdout.closed_by is harness.queue._reader
    with pytest.raises(RuntimeError, match="Cannot send after queue closure"):
        harness.queue.send({})
    stdin.write.assert_not_called()


def test_shutdown_kills_before_waiting_for_blocked_sender(make_queue: Callable[..., Harness]) -> None:
    """Killing the child releases an in-flight write before stdin is closed."""
    writing, killed = Event(), Event()
    stream = Mock()
    harness = make_queue(stdin=stream)
    error = BrokenPipeError("child killed")

    def write(_line: str) -> None:
        writing.set()
        assert killed.wait(TEST_TIMEOUT)
        raise error

    def kill() -> None:
        assert harness.queue._closing.is_set()
        assert writing.is_set()
        stream.close.assert_not_called()
        killed.set()
        harness.child.stdout.eof.set()

    stream.write.side_effect = write
    harness.child.kill.side_effect = kill
    sender, errors = _start(lambda: harness.queue.send({"id": 1}))
    try:
        assert writing.wait(TEST_TIMEOUT)
        harness.queue.shutdown()
    finally:
        killed.set()
        _join(sender)

    assert errors == [error]
    stream.close.assert_called_once_with()


def test_waiting_sender_rechecks_closure(make_queue: Callable[..., Harness]) -> None:
    """A sender already waiting for the write lock cannot write after shutdown starts."""
    harness = make_queue(stdin=Mock())
    attempting = Event()
    lock = Lock()
    observed = MagicMock()

    def enter() -> None:
        attempting.set()
        lock.acquire()

    observed.__enter__.side_effect = enter
    observed.__exit__.side_effect = lambda *_args: lock.release()
    harness.queue._write_lock = observed
    lock.acquire()
    sender, errors = _start(lambda: harness.queue.send({}))
    try:
        assert attempting.wait(TEST_TIMEOUT)
        harness.queue._closing.set()
    finally:
        lock.release()
        _join(sender)
        harness.queue._write_lock = lock

    assert len(errors) == 1
    assert isinstance(errors[0], RuntimeError)
    harness.child.stdin.write.assert_not_called()


def test_shutdown_from_reader_does_not_join_itself(make_queue: Callable[..., Harness]) -> None:
    """An output callback can initiate shutdown without a self-join failure."""
    ready = Event()
    completed = Event()

    def shutdown(_line: str) -> None:
        assert ready.wait(TEST_TIMEOUT)
        harness.queue.shutdown()
        completed.set()

    harness = make_queue(stdout=BlockingOutput("line\n"), on_output=shutdown)
    ready.set()
    _join(harness.queue._reader)

    assert completed.is_set()
    harness.child.kill.assert_called_once_with()
    harness.child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
    assert harness.child.stdout.closed_by is harness.queue._reader


@pytest.mark.parametrize("blocked", ["read", "callback"])
def test_shutdown_reports_reader_timeout_without_cross_thread_close(
    make_queue: Callable[..., Harness],
    monkeypatch: pytest.MonkeyPatch,
    blocked: str,
) -> None:
    """Stalled reads or callbacks produce a timeout; stdout remains reader-owned."""
    entered, release = Event(), Event()

    def output(_line: str) -> None:
        entered.set()
        assert release.wait(TEST_TIMEOUT)

    stdout = BlockingOutput("line\n" if blocked == "callback" else "")
    harness = make_queue(stdout=stdout, on_output=output)
    harness.child.kill.side_effect = None
    assert (entered if blocked == "callback" else stdout.reading).wait(TEST_TIMEOUT)
    monkeypatch.setattr(process, "SHUTDOWN_TIMEOUT", 0.0)
    try:
        with pytest.raises(TimeoutError, match="queue stdout reader"):
            harness.queue.shutdown()
        assert not stdout.closed
        assert harness.child.stdin.closed
    finally:
        release.set()
        stdout.eof.set()
        _join(harness.queue._reader)

    harness.queue.shutdown()
    harness.child.kill.assert_called_once_with()
    assert harness.child.wait.call_args_list == [call(timeout=0.0), call(timeout=0.0)]
    assert stdout.closed_by is harness.queue._reader


def test_shutdown_writer_timeout_can_be_retried(
    make_queue: Callable[..., Harness],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A stuck writer cannot hang shutdown, and later cleanup can finish."""
    harness = make_queue()
    monkeypatch.setattr(process, "SHUTDOWN_TIMEOUT", 0.0)
    harness.queue._write_lock.acquire()
    try:
        with pytest.raises(TimeoutError, match="queue stdin writer"):
            harness.queue.shutdown()
        harness.child.kill.assert_called_once_with()
        harness.child.wait.assert_called_once()
        assert not harness.child.stdin.closed
    finally:
        harness.queue._write_lock.release()
        _join(harness.queue._reader)

    harness.queue.shutdown()
    assert harness.child.stdin.closed
    harness.child.kill.assert_called_once_with()
    assert harness.child.wait.call_args_list == [call(timeout=0.0), call(timeout=0.0)]


def test_shutdown_gives_each_wait_the_full_timeout(
    make_queue: Callable[..., Harness],
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Reaping, taking the write lock, and joining each get five seconds."""
    harness = make_queue()
    lock = Mock(wraps=harness.queue._write_lock)
    join = Mock(wraps=harness.queue._reader.join)
    monkeypatch.setattr(harness.queue, "_write_lock", lock)
    monkeypatch.setattr(harness.queue._reader, "join", join)

    harness.queue.shutdown()

    harness.child.wait.assert_called_once_with(timeout=5.0)
    lock.acquire.assert_called_once_with(timeout=5.0)
    lock.release.assert_called_once_with()
    join.assert_called_once_with(timeout=5.0)


@pytest.mark.parametrize("returncode_after_timeout", [None, 0])
def test_shutdown_reap_timeout_can_be_retried(
    make_queue: Callable[..., Harness],
    returncode_after_timeout: int | None,
) -> None:
    """A failed reap leaves stdin open; a retry polls again and waits again."""
    harness = make_queue()
    error = subprocess.TimeoutExpired("queue", 5)
    successful_wait = harness.child.wait.side_effect

    def wait(*, timeout: float) -> int:
        if harness.child.wait.call_count == 1:
            harness.child.poll.return_value = returncode_after_timeout
            raise error
        return successful_wait(timeout=timeout)

    harness.child.wait.side_effect = wait

    with pytest.raises(subprocess.TimeoutExpired) as caught:
        harness.queue.shutdown()

    assert caught.value is error
    assert harness.queue._closing.is_set()
    assert not harness.child.stdin.closed
    harness.queue.shutdown()
    assert harness.child.stdin.closed
    assert harness.child.wait.call_args_list == [
        call(timeout=process.SHUTDOWN_TIMEOUT),
        call(timeout=process.SHUTDOWN_TIMEOUT),
    ]
    assert harness.child.kill.call_count == (2 if returncode_after_timeout is None else 1)


def test_shutdown_kill_failure_can_be_retried(make_queue: Callable[..., Harness]) -> None:
    """Kill errors propagate before reaping, but a later shutdown can finish."""
    harness = make_queue()
    error = OSError("kill failed")
    kill = harness.child.kill.side_effect
    harness.child.kill.side_effect = error

    with pytest.raises(OSError, match="kill failed") as caught:
        harness.queue.shutdown()

    assert caught.value is error
    assert harness.queue._closing.is_set()
    harness.child.wait.assert_not_called()
    assert not harness.child.stdin.closed
    harness.child.kill.side_effect = kill
    harness.queue.shutdown()
    harness.child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
    assert harness.child.stdin.closed


@pytest.mark.parametrize("error_type", [BrokenPipeError, OSError])
def test_shutdown_suppresses_stdin_close_oserror(
    make_queue: Callable[..., Harness],
    error_type: type[OSError],
) -> None:
    """An OS error closing stdin does not prevent joining or release of the lock."""
    stream = Mock()
    stream.close.side_effect = error_type("broken input")
    harness = make_queue(stdin=stream)

    harness.queue.shutdown()
    harness.queue.shutdown()

    assert stream.close.call_args_list == [call(), call()]
    assert not harness.queue._reader.is_alive()


@pytest.mark.parametrize("returncode", [None, 0, 1, -9])
def test_is_alive_reflects_process_poll(make_queue: Callable[..., Harness], returncode: int | None) -> None:
    """Liveness comes from the child, independently of the closing flag."""
    harness = make_queue()
    harness.child.poll.return_value = returncode

    assert harness.queue.is_alive is (returncode is None)
    harness.queue._closing.set()
    assert harness.queue.is_alive is (returncode is None)
    assert harness.child.poll.call_args_list == [call(), call()]


@pytest.mark.parametrize("returncode", [0, 1])
def test_shutdown_reaps_already_exited_child_without_killing(
    make_queue: Callable[..., Harness],
    returncode: int,
) -> None:
    """An exited child is still waited on and its pipes are cleaned up."""
    harness = make_queue()
    harness.child.poll.return_value = returncode
    harness.child.stdout.eof.set()

    harness.queue.shutdown()

    harness.child.kill.assert_not_called()
    harness.child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
    assert harness.child.stdin.closed
    assert harness.child.stdout.closed_by is harness.queue._reader
    assert not harness.queue._reader.is_alive()


@pytest.mark.parametrize("raise_in_body", [False, True])
def test_context_manager_shuts_down_without_suppressing_body_errors(
    make_queue: Callable[..., Harness],
    *,
    raise_in_body: bool,
) -> None:
    """Context entry returns the queue; either exit path cleans it up."""
    harness = make_queue()
    expectation = pytest.raises(ValueError, match="context body failed") if raise_in_body else nullcontext()

    with expectation, harness.queue as queue:
        assert queue is harness.queue
        assert queue.is_alive
        queue.send({})
        if raise_in_body:
            raise ValueError("context body failed")

    harness.child.kill.assert_called_once_with()
    harness.child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
    assert not harness.queue.is_alive
    assert harness.child.stdin.closed
    assert harness.child.stdout.closed_by is harness.queue._reader
    assert not harness.queue._reader.is_alive()


def test_real_subprocess_round_trip_and_cleanup(monkeypatch: pytest.MonkeyPatch) -> None:
    """Real pipes deliver lines while the child stays alive until owner shutdown."""
    popen = subprocess.Popen
    script = 'import sys; print("ready", flush=True); print(sys.stdin.readline(), end="", flush=True); sys.stdin.read()'
    monkeypatch.setattr(
        process.subprocess,
        "Popen",
        lambda _args, **kwargs: popen([sys.executable, "-u", "-c", script], **kwargs),
    )
    monkeypatch.setattr(process, "assign_to_job", Mock(return_value=True))
    ready, echoed = Event(), Event()
    lines: list[str] = []

    def output(line: str) -> None:
        lines.append(line)
        (ready if line == "ready\n" else echoed).set()

    queue = process.QueueProcess(sys.executable, 1, output)
    try:
        assert ready.wait(TEST_TIMEOUT)
        queue.send({"text": "caf\u00e9"})
        assert echoed.wait(TEST_TIMEOUT)
        assert queue.is_alive
        assert not queue._closing.is_set()
    finally:
        queue.shutdown()

    assert lines == ["ready\n", '{"text":"caf\\u00e9"}\n']
    assert not queue.is_alive
    assert queue._process.returncode is not None
    assert queue._stdin.closed
    assert queue._process.stdout is not None
    assert queue._process.stdout.closed
    assert not queue._reader.is_alive()
