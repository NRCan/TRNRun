"""Tests for ``trnrun.core._process``: the JSON-lines exchange with a trnrund process.

They run ``fake_trnrund.py`` in place of trnrund, which answers each request
as its ``cmd`` names.
"""

import threading
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

from tests.helpers import FAKE_TRNRUND, PYTHON
from trnrun.core import _process as process_module
from trnrun.core._process import DaemonProcess
from trnrun.core.errors import ClosedError, DaemonExitedError, ProtocolError, RequestRejectedError

type StartProcess = Callable[..., DaemonProcess]


@pytest.fixture
def start() -> Iterator[StartProcess]:
    """Return a function starting the fake trnrund; every one started is closed afterwards."""
    started: list[DaemonProcess] = []

    def start(*args: str) -> DaemonProcess:
        """Start the fake trnrund with ``args``."""
        process = DaemonProcess(PYTHON, ["-I", str(FAKE_TRNRUND), *args])
        started.append(process)
        return process

    yield start
    for process in started:
        process.close()


# -----------------------------------------------------------------
# Starting
# -----------------------------------------------------------------
def test_missing_executable_names_it(tmp_path: Path) -> None:
    """Explain how to get trnrund when its executable is missing."""
    missing = tmp_path / "trnrund.exe"

    with pytest.raises(FileNotFoundError, match="trnrund executable not found") as raised:
        _ = DaemonProcess(missing, [])

    assert str(missing) in str(raised.value)


def test_start_passes_the_arguments(start: StartProcess) -> None:
    """Start trnrund with the given arguments."""
    process = start("--trnrun:trnrun.exe", "--maxConcurrent:2")

    assert process.request({"cmd": "ready"})["args"] == ["--trnrun:trnrun.exe", "--maxConcurrent:2"]


def test_no_thread_is_started(start: StartProcess) -> None:
    """Run every request on the caller's thread."""
    before = threading.active_count()

    process = start()
    _ = process.request({"cmd": "ready"})

    assert threading.active_count() == before


# -----------------------------------------------------------------
# Requests
# -----------------------------------------------------------------
def test_request_returns_the_reply_with_increasing_ids(start: StartProcess) -> None:
    """Number each request and return the reply that repeats its id."""
    process = start()

    first = process.request({"cmd": "ready"})
    second = process.request({"cmd": "ready"})

    assert (first["ok"], first["id"]) == (True, 1)
    assert second["id"] == 2


def test_rejected_request_raises_request_rejected_error(start: StartProcess) -> None:
    """Raise trnrund's error for a rejected request, still a ValueError, and keep serving."""
    process = start()

    with pytest.raises(RequestRejectedError, match="Rejected on purpose") as raised:
        _ = process.request({"cmd": "reject"})
    assert isinstance(raised.value, ValueError)
    with pytest.raises(RequestRejectedError, match="trnrund rejected the request"):
        _ = process.request({"cmd": "bare_reject"})
    assert process.request({"cmd": "ready"})["ok"] is True


@pytest.mark.parametrize(
    "line",
    [
        "not json",
        "[1, 2, 3]",
        '{"event": "changed", "revision": 4}',
        '{"something": "else"}',
        '{"id": 99, "ok": true}',
        '{"id": 1, "ok": "yes"}',
    ],
)
def test_a_line_that_is_not_the_reply_raises_protocol_error_and_closes(start: StartProcess, line: str) -> None:
    """Refuse an extra, malformed or mismatched line, and close trnrund, whose replies are out of step."""
    process = start()

    with pytest.raises(ProtocolError, match="trnrund wrote a line that is not") as raised:
        _ = process.request({"cmd": "say", "line": line})
    assert isinstance(raised.value, RuntimeError)
    with pytest.raises(ClosedError, match="trnrund is closed"):
        _ = process.request({"cmd": "ready"})


def test_requests_from_several_threads_get_their_own_replies(start: StartProcess) -> None:
    """Serialize requests, so concurrent callers never swap replies."""
    process = start()
    replies: list[dict[str, object]] = []
    lock = threading.Lock()

    def send() -> None:
        """Send a few requests and keep their replies."""
        for _ in range(10):
            reply = process.request({"cmd": "ready"})
            with lock:
                replies.append(reply)

    threads = [threading.Thread(target=send) for _ in range(4)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()

    assert sorted(int(str(reply["id"])) for reply in replies) == list(range(1, 41))


# -----------------------------------------------------------------
# Exit
# -----------------------------------------------------------------
def test_crash_is_reported_with_its_diagnostics(start: StartProcess) -> None:
    """Raise DaemonExitedError with the exit code and stderr, for every later request."""
    process = start()

    with pytest.raises(DaemonExitedError, match="trnrund exited with code 3: boom"):
        _ = process.request({"cmd": "crash"})
    with pytest.raises(DaemonExitedError, match="code 3") as raised:
        _ = process.request({"cmd": "ready"})
    assert isinstance(raised.value, RuntimeError)
    assert (raised.value.exit_code, raised.value.diagnostics) == (3, "boom")


def test_unexpected_exit_with_code_0_is_a_close(start: StartProcess) -> None:
    """Raise ClosedError for a clean exit."""
    process = start()
    _ = process.request({"cmd": "exit"})

    with pytest.raises(ClosedError, match="trnrund is closed"):
        _ = process.request({"cmd": "ready"})


def test_unexpected_exit_with_an_error_is_a_crash(start: StartProcess) -> None:
    """Raise DaemonExitedError for a failed exit."""
    process = start()
    _ = process.request({"cmd": "exit", "code": 2})

    with pytest.raises(DaemonExitedError, match="trnrund exited with code 2: bye"):
        _ = process.request({"cmd": "ready"})


def test_close_ends_trnrund_and_is_idempotent(start: StartProcess) -> None:
    """Close stdin, wait for the exit, and allow closing again."""
    process = start()
    _ = process.request({"cmd": "ready"})

    process.close()
    process.close()

    assert process._popen.returncode == 0
    with pytest.raises(ClosedError, match="trnrund is closed"):
        _ = process.request({"cmd": "ready"})


def test_close_after_a_crash(start: StartProcess) -> None:
    """Close a daemon that already exited without raising."""
    process = start()
    with pytest.raises(DaemonExitedError):
        _ = process.request({"cmd": "crash"})

    process.close()

    with pytest.raises(ClosedError):  # Closed: its crash is no longer reported.
        _ = process.request({"cmd": "ready"})


def test_close_kills_a_trnrund_that_does_not_exit(start: StartProcess, monkeypatch: pytest.MonkeyPatch) -> None:
    """Kill a daemon still running after its close grace period, so closing never hangs."""
    monkeypatch.setattr(process_module, "_CLOSE_WAIT", 0.5)
    process = start("--ignore-eof")
    _ = process.request({"cmd": "ready"})

    process.close()

    assert process._popen.returncode not in {None, 0}  # Killed, not exited.
    with pytest.raises(ClosedError):
        _ = process.request({"cmd": "ready"})
