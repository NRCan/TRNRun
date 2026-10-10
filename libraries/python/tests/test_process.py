# ruff: noqa: S101, SLF001

from __future__ import annotations

import io
import subprocess
import sys
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path
from queue import Queue
from threading import Event, Thread
from time import monotonic, sleep
from typing import IO, Any, cast
from unittest.mock import MagicMock, Mock, call

import pytest

from trnrun import process
from trnrun.config import BUNDLED_TRNRUND_PATH

TEST_TIMEOUT = 10.0
STARTED = '{"ok":true}\n'  # Reply to the constructor's ready request.


class ReplyPipe:
    """Daemon stdout fed by the test; reads block until a reply or EOF arrives."""

    def __init__(self, *lines: str) -> None:
        """Queue the startup reply, then the given reply lines."""
        self.lines: Queue[str] = Queue()
        self.reading: Event = Event()
        self.closed: bool = False
        for line in (STARTED, *lines):
            self.lines.put(line)

    def reply(self, line: str) -> None:
        """Deliver one reply line."""
        self.lines.put(line)

    def eof(self) -> None:
        """Close the pipe from the daemon's side."""
        self.lines.put("")

    def readline(self) -> str:
        """Block for the next line; EOF stays EOF."""
        self.reading.set()
        line = self.lines.get(timeout=TEST_TIMEOUT)
        if not line:
            self.lines.put("")
        return line

    def close(self) -> None:
        """Record closure."""
        self.closed = True


@dataclass
class Harness:
    """A daemon process backed by controlled child-process boundaries."""

    daemon: process.DaemonProcess
    child: Mock
    popen: Mock


@pytest.fixture
def executables(tmp_path: Path) -> tuple[Path, Path]:
    """Create placeholder daemon and runner executables."""
    daemon, runner = tmp_path / "trnrund.exe", tmp_path / "trnrun.exe"
    daemon.touch()
    runner.touch()
    return daemon, runner


@pytest.fixture
def make_daemon(
    monkeypatch: pytest.MonkeyPatch,
    executables: tuple[Path, Path],
) -> Iterator[Callable[..., Harness]]:
    """Build daemons and ensure each is shut down by the test."""
    harnesses: list[Harness] = []
    monkeypatch.setattr(process, "assign_to_job", Mock(return_value=True))

    def create(
        stdin: IO[str] | Mock | None = None,
        stdout: ReplyPipe | Mock | None = None,
        stderr: IO[str] | None = None,
    ) -> Harness:
        child = Mock(stdin=stdin if stdin is not None else io.StringIO())
        child.stdout = stdout if stdout is not None else ReplyPipe()
        child.stderr = stderr if stderr is not None else io.StringIO()
        if isinstance(child.stdout, ReplyPipe):
            child.kill.side_effect = child.stdout.eof
        child.poll.return_value = None
        child.returncode = None

        def wait(*, timeout: float) -> int:
            assert timeout == process.SHUTDOWN_TIMEOUT
            child.poll.return_value = 0
            child.returncode = 0
            return 0

        child.wait.side_effect = wait
        popen = Mock(return_value=child)
        monkeypatch.setattr(process.subprocess, "Popen", popen)

        daemon = process.DaemonProcess(*executables, 3)
        # Leave tests only the traffic after the startup request.
        if isinstance(child.stdout, ReplyPipe):
            child.stdout.reading.clear()
        if isinstance(child.stdin, Mock):
            child.stdin.reset_mock()
        harness = Harness(daemon, child, popen)
        harnesses.append(harness)
        return harness

    yield create

    for harness in harnesses:
        if isinstance(harness.child.stdout, ReplyPipe):
            harness.child.stdout.eof()
        harness.daemon.shutdown()


def _start(action: Callable[[], object]) -> tuple[Thread, list[Exception]]:
    """Run an operation in a worker while retaining its actual exception."""
    errors: list[Exception] = []

    def run() -> None:
        try:
            _ = action()
        except Exception as exc:  # noqa: BLE001 - inspect worker failures in the test thread
            errors.append(exc)

    thread = Thread(target=run, daemon=True)
    thread.start()
    return thread, errors


def _join(thread: Thread) -> None:
    """Bound every test wait, so a regression fails instead of hanging pytest."""
    thread.join(TEST_TIMEOUT)
    assert not thread.is_alive(), "worker did not finish"


@pytest.mark.parametrize(
    ("missing", "message"),
    [(0, r"TRNRun daemon executable not found: .*missing\.exe"), (1, r"TRNRun executable not found: .*missing\.exe")],
)
def test_init_rejects_missing_executables(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
    executables: tuple[Path, Path],
    missing: int,
    message: str,
) -> None:
    """A missing daemon or runner fails early, without spawning."""
    popen = Mock()
    monkeypatch.setattr(process.subprocess, "Popen", popen)
    daemon, runner = executables
    if missing == 0:
        daemon = tmp_path / "missing.exe"
    else:
        runner = tmp_path / "missing.exe"

    with pytest.raises(FileNotFoundError, match=message):
        process.DaemonProcess(daemon, runner, 1)

    popen.assert_not_called()


def test_init_spawns_configured_process_and_assigns_job(
    make_daemon: Callable[..., Harness],
    monkeypatch: pytest.MonkeyPatch,
    executables: tuple[Path, Path],
) -> None:
    """Construction passes the runner and concurrency, with three text pipes."""
    assign = Mock(return_value=True)
    monkeypatch.setattr(process, "assign_to_job", assign)
    harness = make_daemon()
    daemon, runner = executables

    harness.popen.assert_called_once_with(
        [str(daemon.absolute()), f"--trnrun:{runner.absolute()}", "--maxConcurrent:3"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        encoding="utf-8",
        errors="replace",
        creationflags=process.CREATE_NO_WINDOW,
    )
    assign.assert_called_once_with(harness.child)
    assert harness.child.stdin.getvalue() == '{"cmd":"ready"}\n'


@pytest.mark.parametrize("missing", ["stdin", "stdout", "stderr"])
def test_init_missing_pipe_cleans_up_available_resources(
    monkeypatch: pytest.MonkeyPatch,
    executables: tuple[Path, Path],
    missing: str,
) -> None:
    """Missing pipes fail construction and release the process and remaining pipes."""
    streams = {name: io.StringIO() for name in ("stdin", "stdout", "stderr")}
    child = Mock(**streams)
    setattr(child, missing, None)
    monkeypatch.setattr(process.subprocess, "Popen", Mock(return_value=child))
    assign = Mock(return_value=True)
    monkeypatch.setattr(process, "assign_to_job", assign)

    with pytest.raises(RuntimeError, match=r"^TRNRun daemon pipes are unavailable$"):
        process.DaemonProcess(*executables, 1)

    assign.assert_not_called()
    child.kill.assert_called_once_with()
    child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
    for name, stream in streams.items():
        if name != missing:
            assert stream.closed


def test_init_reports_daemon_startup_failure_and_cleans_up(
    monkeypatch: pytest.MonkeyPatch,
    executables: tuple[Path, Path],
) -> None:
    """A daemon that exits instead of answering fails construction with its diagnostics."""
    child = Mock(stdin=io.StringIO(), stdout=io.StringIO(), stderr=io.StringIO("'maxConcurrent' must be at least 1\n"))
    child.returncode = 2
    monkeypatch.setattr(process.subprocess, "Popen", Mock(return_value=child))
    monkeypatch.setattr(process, "assign_to_job", Mock(return_value=True))

    with pytest.raises(RuntimeError, match=r"^TRNRun daemon exited with code 2: 'maxConcurrent' must be at least 1$"):
        process.DaemonProcess(*executables, 0)

    child.kill.assert_called_once_with()
    assert child.stdin.closed
    assert child.stdout.closed
    assert child.stderr.closed


def test_init_rejected_ready_cleans_up(
    monkeypatch: pytest.MonkeyPatch,
    executables: tuple[Path, Path],
) -> None:
    """A rejected readiness handshake fails startup and releases the daemon."""
    child = Mock(
        stdin=io.StringIO(),
        stdout=io.StringIO('{"ok":false,"error":"Unknown cmd: ready"}\n'),
        stderr=io.StringIO(),
    )
    monkeypatch.setattr(process.subprocess, "Popen", Mock(return_value=child))
    monkeypatch.setattr(process, "assign_to_job", Mock(return_value=True))

    with pytest.raises(ValueError, match="^Unknown cmd: ready$"):
        process.DaemonProcess(*executables, 1)

    child.kill.assert_called_once_with()
    child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
    for stream in (child.stdin, child.stdout, child.stderr):
        assert stream.closed


@pytest.mark.parametrize("failure", ["spawn", "job"])
def test_init_failure_releases_acquired_resources(
    monkeypatch: pytest.MonkeyPatch,
    executables: tuple[Path, Path],
    failure: str,
) -> None:
    """Startup failures preserve their cause and release every acquired resource."""
    child = Mock(stdin=io.StringIO(), stdout=io.StringIO(), stderr=io.StringIO())
    error = RuntimeError("startup failed")
    popen = Mock(return_value=child)
    assign = Mock(return_value=True)
    monkeypatch.setattr(process.subprocess, "Popen", popen)
    monkeypatch.setattr(process, "assign_to_job", assign)
    if failure == "spawn":
        popen.side_effect = error
    else:
        assign.side_effect = error

    with pytest.raises(RuntimeError) as caught:
        process.DaemonProcess(*executables, 1)

    assert caught.value is error
    if failure == "spawn":
        child.kill.assert_not_called()
        child.wait.assert_not_called()
    else:
        child.kill.assert_called_once_with()
        child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
        for stream in (child.stdin, child.stdout, child.stderr):
            assert stream.closed


def test_startup_cleanup_preserves_original_exception(
    monkeypatch: pytest.MonkeyPatch,
    executables: tuple[Path, Path],
) -> None:
    """A cleanup failure must not hide the constructor's actual failure."""
    child = Mock(stdin=io.StringIO(), stdout=io.StringIO(), stderr=io.StringIO())
    child.kill.side_effect = OSError("kill failed")
    original = RuntimeError("job failed")
    monkeypatch.setattr(process.subprocess, "Popen", Mock(return_value=child))
    monkeypatch.setattr(process, "assign_to_job", Mock(side_effect=original))

    with pytest.raises(RuntimeError) as caught:
        process.DaemonProcess(*executables, 1)

    assert caught.value is original
    child.kill.assert_called_once_with()


def test_request_writes_compact_json_line_and_returns_reply(make_daemon: Callable[..., Harness]) -> None:
    """Requests use compact, strict, one-line JSON framing; the reply is decoded."""
    stream = MagicMock()
    harness = make_daemon(stdin=stream, stdout=ReplyPipe('{"ok":true,"logs":[]}\n'))

    reply = harness.daemon.request({"cmd": "logs", "values": [True, None, 2]})

    assert reply == {"ok": True, "logs": []}
    assert stream.mock_calls == [call.write('{"cmd":"logs","values":[true,null,2]}\n'), call.flush()]


def test_request_rejects_nonstandard_nan_without_writing(make_daemon: Callable[..., Harness]) -> None:
    """Invalid JSON numbers fail before any pipe access."""
    stream = MagicMock()
    harness = make_daemon(stdin=stream)

    with pytest.raises(ValueError, match="Out of range float values are not JSON compliant"):
        harness.daemon.request({"value": float("nan")})

    stream.write.assert_not_called()


def test_rejected_request_raises_daemon_message(make_daemon: Callable[..., Harness]) -> None:
    """An ``ok: false`` reply becomes a ValueError carrying the daemon's error."""
    harness = make_daemon(stdout=ReplyPipe('{"ok":false,"error":"Deck file not found: x.dck"}\n'))

    with pytest.raises(ValueError, match=r"^Deck file not found: x\.dck$"):
        harness.daemon.request({"cmd": "add"})


def test_malformed_reply_raises_value_error(make_daemon: Callable[..., Harness]) -> None:
    """A reply without ``ok: true`` or an error message still raises a ValueError."""
    harness = make_daemon(stdout=ReplyPipe('{"simulations":[]}\n'))

    with pytest.raises(ValueError, match=r"^TRNRun daemon sent an invalid reply: \{\"simulations\":\[\]\}$"):
        harness.daemon.request({"cmd": "pull"})


@pytest.mark.parametrize("operation", ["write", "flush"])
def test_broken_pipe_reports_exit_code_and_diagnostics(make_daemon: Callable[..., Harness], operation: str) -> None:
    """A daemon that closes stdin surfaces its diagnostics, not a raw pipe error."""
    stdin = Mock()
    harness = make_daemon(stdin=stdin, stderr=io.StringIO("Fatal daemon error\n"))
    error = BrokenPipeError("daemon closed stdin")
    getattr(stdin, operation).side_effect = error

    def wait(*, timeout: float) -> int:
        del timeout
        harness.child.returncode = 2
        return 2

    harness.child.wait.side_effect = wait
    with pytest.raises(RuntimeError, match=r"^TRNRun daemon exited with code 2: Fatal daemon error$") as caught:
        harness.daemon.request({"cmd": "pull"})

    assert caught.value.__cause__ is error


def test_exit_diagnostics_are_read_under_request_lock(make_daemon: Callable[..., Harness]) -> None:
    """Exit diagnostics cannot race with another request or pipe closure."""
    stdout = ReplyPipe()
    stdout.eof()
    stderr = Mock()
    harness = make_daemon(stdout=stdout, stderr=stderr)

    def read() -> str:
        acquired = harness.daemon._lock.acquire(blocking=False)
        if acquired:
            harness.daemon._lock.release()
        assert not acquired, "stderr must be read while holding the request lock"
        return "Fatal daemon error\n"

    stderr.read.side_effect = read
    with pytest.raises(RuntimeError, match="Fatal daemon error"):
        harness.daemon.request({"cmd": "pull"})

    stderr.read.assert_called_once_with()


def test_eof_reports_exit_code_and_diagnostics(make_daemon: Callable[..., Harness]) -> None:
    """A daemon that exits mid-request surfaces its stderr diagnostics."""
    stdout = ReplyPipe()
    stdout.eof()
    harness = make_daemon(stdout=stdout, stderr=io.StringIO("Unknown option: --x\n"))

    def wait(*, timeout: float) -> int:
        del timeout
        harness.child.returncode = 2
        return 2

    harness.child.wait.side_effect = wait
    with pytest.raises(RuntimeError, match=r"^TRNRun daemon exited with code 2: Unknown option: --x$"):
        harness.daemon.request({"cmd": "pull"})


def test_concurrent_requests_never_interleave_replies(make_daemon: Callable[..., Harness]) -> None:
    """A second caller cannot write until the first caller has read its reply."""
    stdin = Mock()
    stdout = ReplyPipe()
    harness = make_daemon(stdin=stdin, stdout=stdout)
    results: list[object] = []
    first, first_errors = _start(lambda: results.append(harness.daemon.request({"id": 1})))
    assert stdout.reading.wait(TEST_TIMEOUT)
    stdout.reading.clear()
    second, second_errors = _start(lambda: results.append(harness.daemon.request({"id": 2})))
    try:
        stdin.write.assert_called_once_with('{"id":1}\n')
        stdout.reply('{"ok":true,"id":1}\n')
        assert stdout.reading.wait(TEST_TIMEOUT)
        stdout.reply('{"ok":true,"id":2}\n')
    finally:
        _join(first)
        _join(second)

    assert not first_errors
    assert not second_errors
    assert results == [{"ok": True, "id": 1}, {"ok": True, "id": 2}]
    assert stdin.write.call_args_list == [call('{"id":1}\n'), call('{"id":2}\n')]


def test_shutdown_kills_before_waiting_for_blocked_request(make_daemon: Callable[..., Harness]) -> None:
    """Killing the daemon delivers EOF to an in-flight request before pipes close."""
    stdout = ReplyPipe()
    harness = make_daemon(stdout=stdout)
    requester, errors = _start(lambda: harness.daemon.request({"cmd": "pull"}))
    assert stdout.reading.wait(TEST_TIMEOUT)

    harness.daemon.shutdown()
    _join(requester)

    assert len(errors) == 1
    assert type(errors[0]) is RuntimeError
    assert str(errors[0]) == "TRNRun daemon was shut down"
    assert stdout.closed
    assert harness.child.stdin.closed


def test_shutdown_repeats_kill_wait_and_close(make_daemon: Callable[..., Harness]) -> None:
    """Sequential shutdowns repeat every step, then reject further requests."""
    stdin = Mock()
    harness = make_daemon(stdin=stdin)
    operations = Mock()
    operations.attach_mock(harness.child.kill, "kill")
    operations.attach_mock(harness.child.wait, "wait")
    operations.attach_mock(stdin.close, "close")

    harness.daemon.shutdown()
    harness.daemon.shutdown()

    assert operations.mock_calls == [
        call.kill(),
        call.wait(timeout=process.SHUTDOWN_TIMEOUT),
        call.close(),
    ] * 2
    with pytest.raises(RuntimeError, match="Cannot send after daemon closure"):
        harness.daemon.request({})
    stdin.write.assert_not_called()


def test_shutdown_reap_timeout_can_be_retried(make_daemon: Callable[..., Harness]) -> None:
    """A failed reap leaves stdin open; a retry kills and waits again."""
    harness = make_daemon()
    error = subprocess.TimeoutExpired("daemon", 5)
    successful_wait = harness.child.wait.side_effect

    def wait(*, timeout: float) -> int:
        if harness.child.wait.call_count == 1:
            raise error
        return successful_wait(timeout=timeout)

    harness.child.wait.side_effect = wait

    with pytest.raises(subprocess.TimeoutExpired) as caught:
        harness.daemon.shutdown()

    assert caught.value is error
    assert harness.daemon._closing
    assert not harness.child.stdin.closed
    harness.daemon.shutdown()
    assert harness.child.stdin.closed
    assert harness.child.kill.call_count == 2


def test_shutdown_kill_failure_can_be_retried(make_daemon: Callable[..., Harness]) -> None:
    """Kill errors propagate before reaping, but a later shutdown can finish."""
    harness = make_daemon()
    error = OSError("kill failed")
    kill = harness.child.kill.side_effect
    harness.child.kill.side_effect = error

    with pytest.raises(OSError, match="kill failed") as caught:
        harness.daemon.shutdown()

    assert caught.value is error
    harness.child.wait.assert_not_called()
    assert not harness.child.stdin.closed
    harness.child.kill.side_effect = kill
    harness.daemon.shutdown()
    harness.child.wait.assert_called_once_with(timeout=process.SHUTDOWN_TIMEOUT)
    assert harness.child.stdin.closed


def test_wait_reaps_without_killing_then_rejects_requests(make_daemon: Callable[..., Harness]) -> None:
    """Waiting for a daemon that exits on its own never kills it, and closes the pipes."""
    stdin = Mock()
    harness = make_daemon(stdin=stdin)
    harness.child.wait.side_effect = None

    harness.daemon.wait(2.0)

    harness.child.kill.assert_not_called()
    harness.child.wait.assert_called_once_with(timeout=2.0)
    stdin.close.assert_called_once_with()
    assert harness.child.stdout.closed
    with pytest.raises(RuntimeError, match="Cannot send after daemon closure"):
        harness.daemon.request({})
    stdin.write.assert_not_called()


def test_wait_timeout_leaves_the_daemon_for_shutdown(make_daemon: Callable[..., Harness]) -> None:
    """A wait that times out keeps the pipes open, and shutdown can still kill."""
    harness = make_daemon()
    error = subprocess.TimeoutExpired("daemon", 1)
    successful_wait = harness.child.wait.side_effect
    harness.child.wait.side_effect = error

    with pytest.raises(subprocess.TimeoutExpired) as caught:
        harness.daemon.wait(1.0)

    assert caught.value is error
    assert not harness.child.stdin.closed
    harness.child.wait.side_effect = successful_wait
    harness.daemon.shutdown()
    harness.child.kill.assert_called_once_with()
    assert harness.child.stdin.closed


@pytest.mark.parametrize("error_type", [BrokenPipeError, OSError])
def test_shutdown_suppresses_close_oserror(make_daemon: Callable[..., Harness], error_type: type[OSError]) -> None:
    """An OS error closing one pipe does not prevent closing the others or releasing the lock."""
    stream = Mock()
    stream.close.side_effect = error_type("broken input")
    harness = make_daemon(stdin=stream)

    harness.daemon.shutdown()
    harness.daemon.shutdown()

    assert stream.close.call_args_list == [call(), call()]
    assert harness.child.stdout.closed
    assert harness.child.stderr.closed
    assert harness.daemon._lock.acquire(blocking=False)
    harness.daemon._lock.release()


def test_real_subprocess_round_trip_and_cleanup(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Real pipes carry UTF-8 requests and replies until owner shutdown."""
    popen = subprocess.Popen
    script = (
        "import json, sys\n"
        "for line in sys.stdin:\n"
        "    print(json.dumps({'ok': True, 'echo': json.loads(line)}), flush=True)\n"
    )
    monkeypatch.setattr(
        process.subprocess,
        "Popen",
        lambda _args, **kwargs: popen([sys.executable, "-u", "-c", script], **kwargs),
    )
    monkeypatch.setattr(process, "assign_to_job", Mock(return_value=True))
    runner = tmp_path / "trnrun.exe"
    runner.touch()

    daemon = process.DaemonProcess(sys.executable, runner, 1)
    try:
        assert daemon.request({"text": "café"}) == {"ok": True, "echo": {"text": "café"}}
        assert daemon._process.poll() is None
    finally:
        daemon.shutdown()

    assert daemon._process.returncode is not None
    assert daemon._stdin.closed
    assert daemon._stdout.closed


def test_real_daemon_round_trip(tmp_path: Path, fake_trnrun: Path) -> None:
    """The bundled daemon accepts a run, reports each change once, and forgets it once reported finished."""
    deck = tmp_path / "done-a.dck"
    deck.touch()
    daemon = process.DaemonProcess(BUNDLED_TRNRUND_PATH, fake_trnrun, 1)
    try:
        assert daemon.request({"cmd": "ready"}) == {"ok": True}
        assert daemon.request({"cmd": "add", "runId": "1", "deckFile": str(deck)}) == {"ok": True}
        with pytest.raises(ValueError, match="Invalid or duplicate runId: 1"):
            daemon.request({"cmd": "add", "runId": "1", "deckFile": str(deck)})
        deadline = monotonic() + TEST_TIMEOUT
        logs: list[object] = []
        simulation: dict[str, Any] = {"state": "QUEUED"}
        while simulation["state"] != "FINISHED" and monotonic() < deadline:
            for simulation in cast("list[dict[str, Any]]", daemon.request({"cmd": "pull"})["simulations"]):
                logs.extend(simulation["logs"])
            sleep(0.01)
        assert simulation["state"] == "FINISHED"
        assert daemon.request({"cmd": "pull"}) == {"ok": True, "simulations": []}
        with pytest.raises(ValueError, match="Unknown cmd: remove"):
            daemon.request({"cmd": "remove", "runId": "1"})
    finally:
        daemon.shutdown()

    assert simulation["succeeded"] is True
    assert len(logs) == sum(simulation[name] for name in ("notices", "warnings", "fatals")) == 3


@pytest.mark.parametrize(
    ("max_concurrent", "message"),
    [
        (0, "'maxConcurrent' must be at least 1"),
        (2.5, "invalid integer: 2.5"),
        (True, "invalid integer: True"),
    ],
)
def test_real_daemon_validates_concurrency(fake_trnrun: Path, max_concurrent: object, message: str) -> None:
    """The daemon's own validation reaches the constructor."""
    with pytest.raises(RuntimeError, match=f"^TRNRun daemon exited with code 2: {message}$"):
        process.DaemonProcess(BUNDLED_TRNRUND_PATH, fake_trnrun, max_concurrent)  # pyright: ignore[reportArgumentType]
