"""Tests for ``trnrun.process``: the JSON-lines exchange with a trnrund process.

They run ``fake_trnrund.py`` in place of trnrund, which answers each request
as its ``cmd`` names.
"""

import subprocess
import threading
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

from tests.helpers import FAKE_TRNRUND, PYTHON
from trnrun import process as process_module
from trnrun.process import DaemonProcess

type StartProcess = Callable[..., DaemonProcess]


@pytest.fixture
def start() -> Iterator[StartProcess]:
    """Return a function starting the fake trnrund; every one started is closed afterwards."""
    started: list[DaemonProcess] = []

    def start(*args: str, request_timeout: float = 10.0) -> DaemonProcess:
        """Start the fake trnrund with ``args``."""
        process = DaemonProcess(PYTHON, ["-I", str(FAKE_TRNRUND), *args], request_timeout=request_timeout)
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
        _ = DaemonProcess(missing, [], request_timeout=1.0)

    assert str(missing) in str(raised.value)


def test_start_passes_the_arguments_and_assigns_the_job(
    start: StartProcess,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Start trnrund with the given arguments, inside the kill-on-close job."""
    assigned: list[subprocess.Popen[str]] = []
    monkeypatch.setattr(process_module, "assign_to_job", assigned.append)

    process = start("--database:runs.sqlite3", "--maxConcurrent:2")

    assert process.request({"cmd": "ready"})["args"] == ["--database:runs.sqlite3", "--maxConcurrent:2"]
    assert len(assigned) == 1


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


def test_rejected_request_raises_value_error(start: StartProcess) -> None:
    """Raise trnrund's error for a rejected request, and keep serving."""
    process = start()

    with pytest.raises(ValueError, match="Rejected on purpose"):
        _ = process.request({"cmd": "reject"})
    with pytest.raises(ValueError, match="trnrund rejected the request"):
        _ = process.request({"cmd": "bare_reject"})
    assert process.request({"cmd": "ready"})["ok"] is True


def test_request_timeout_skips_the_late_reply(start: StartProcess) -> None:
    """Raise TimeoutError, and later match replies by id so the late one is not mistaken."""
    process = start(request_timeout=0.2)

    with pytest.raises(TimeoutError, match="'mute'"):
        _ = process.request({"cmd": "mute"})

    reply = process.request({"cmd": "ready"}, timeout=10.0)
    assert reply["id"] == 2
    assert "late" not in reply


def test_lines_that_are_not_replies_are_skipped(start: StartProcess) -> None:
    """Skip non-JSON, non-object and unknown lines, then still get the reply."""
    process = start()

    reply = process.request({"cmd": "noise"})

    assert reply["ok"] is True


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
# Change notifications
# -----------------------------------------------------------------
def test_wait_for_change_wakes_on_a_later_revision(start: StartProcess) -> None:
    """Return True once trnrund announces a revision after the one given."""
    process = start()

    assert process.wait_for_change(0, timeout=0.05) is False
    _ = process.request({"cmd": "notify", "revision": 5})

    assert process.wait_for_change(4, timeout=5.0) is True
    assert process.wait_for_change(5, timeout=0.05) is False


def test_wait_for_change_keeps_the_largest_revision(start: StartProcess) -> None:
    """Never go back to an older revision announced late."""
    process = start()
    _ = process.request({"cmd": "notify", "revision": 7})
    _ = process.request({"cmd": "notify", "revision": 3})

    assert process.wait_for_change(6, timeout=0.05) is True


def test_wait_for_change_from_another_thread(start: StartProcess) -> None:
    """Wake a waiter blocked in another thread."""
    process = start()
    woke: list[bool] = []
    waiter = threading.Thread(target=lambda: woke.append(process.wait_for_change(0, timeout=10.0)))
    waiter.start()

    _ = process.request({"cmd": "notify", "revision": 1})
    waiter.join(10.0)

    assert woke == [True]


# -----------------------------------------------------------------
# Exit
# -----------------------------------------------------------------
def test_crash_is_reported_with_its_diagnostics(start: StartProcess) -> None:
    """Raise RuntimeError with the exit code and stderr, for this and every later request."""
    process = start()

    with pytest.raises(RuntimeError, match="trnrund exited with code 3: boom"):
        _ = process.request({"cmd": "crash"})
    with pytest.raises(RuntimeError, match="code 3"):
        _ = process.request({"cmd": "ready"})

    error = process.exit_error()
    assert isinstance(error, RuntimeError)
    assert "boom" in str(error)
    assert process.wait_for_change(0, timeout=5.0) is True  # Its end wakes waiters.


def test_exit_error_is_none_while_running(start: StartProcess) -> None:
    """Report no error for a daemon that is still serving."""
    process = start()
    _ = process.request({"cmd": "ready"})

    assert process.exit_error() is None


def test_wait_returns_once_trnrund_exits_cleanly(start: StartProcess) -> None:
    """Treat an exit after wait() as expected, and close the process."""
    process = start()
    _ = process.request({"cmd": "exit"})

    assert process.wait(timeout=10.0) is True
    assert process.exit_error() is None
    with pytest.raises(RuntimeError, match="trnrund is closed"):
        _ = process.request({"cmd": "ready"})


def test_wait_raises_when_trnrund_exits_with_an_error(start: StartProcess) -> None:
    """Raise the exit code and diagnostics of a failed exit."""
    process = start()
    _ = process.request({"cmd": "exit", "code": 2})

    with pytest.raises(RuntimeError, match="trnrund exited with code 2: bye"):
        _ = process.wait(timeout=10.0)


def test_wait_times_out_and_leaves_trnrund_running(start: StartProcess) -> None:
    """Return False without closing a daemon that has not exited."""
    process = start()

    assert process.wait(timeout=0.05) is False
    assert process.request({"cmd": "ready"})["ok"] is True


def test_close_ends_trnrund_and_is_idempotent(start: StartProcess) -> None:
    """Close stdin, wait for the exit, and allow closing again."""
    process = start()
    _ = process.request({"cmd": "ready"})

    process.close()
    process.close()

    assert process.exit_error() is None
    with pytest.raises(RuntimeError, match="trnrund is closed"):
        _ = process.request({"cmd": "ready"})


def test_close_after_a_crash(start: StartProcess) -> None:
    """Close a daemon that already exited without raising."""
    process = start()
    with pytest.raises(RuntimeError):
        _ = process.request({"cmd": "crash"})

    process.close()

    assert process.exit_error() is None  # Closed: its exit is no longer reported.


def test_close_kills_a_trnrund_that_does_not_exit(start: StartProcess, monkeypatch: pytest.MonkeyPatch) -> None:
    """Kill a daemon still running after its close grace period, so closing never hangs."""
    monkeypatch.setattr(process_module, "_CLOSE_WAIT", 0.5)
    process = start("--ignore-eof")
    _ = process.request({"cmd": "ready"})

    process.close()

    assert process._popen.returncode not in {None, 0}  # Killed, not exited.
    assert process.wait_for_change(0, timeout=5.0) is True  # Its stdout ended.
