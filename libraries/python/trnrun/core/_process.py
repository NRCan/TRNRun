"""The trnrund process: start it, exchange JSON lines with it, and report its exit."""

import json
import queue
import subprocess
import threading
import time
from contextlib import suppress
from pathlib import Path
from typing import cast

from trnrun.core.errors import ClosedError, DaemonExitedError, RequestRejectedError

_EXIT_WAIT = 10.0  # Seconds to wait for trnrund to exit once its stdout ended.
_CLOSE_WAIT = 10.0  # Seconds trnrund gets to save interrupted runs and exit once stdin is closed.


class DaemonProcess:
    """A running trnrund, read by a background thread.

    The thread sorts each stdout line: replies go to the waiting request,
    matched by ``id``, and ``changed`` notifications wake ``wait_for_changes``.
    trnrund's stdout ends only after its final changes are saved, so the end
    of stdout is how a crashed daemon is noticed. The thread then records the
    exit before waking waiters, so they never wait for it themselves. stderr
    is captured rather than shown: trnrund writes to it only before a fatal
    exit, and that text is added to the DaemonExitedError reporting the exit.

    Requests are serialized, so any thread may send one.
    """

    def __init__(self, trnrund_path: str | Path, args: list[str], *, request_timeout: float) -> None:
        """Start trnrund with ``args`` without a console window; do not wait for it."""
        self._request_timeout: float = request_timeout
        # Serializes requests, so replies arrive in the order they are awaited.
        self._request_lock: threading.Lock = threading.Lock()
        self._next_id: int = 0
        # Replies read from stdout; None marks its end.
        self._replies: queue.SimpleQueue[dict[str, object] | None] = queue.SimpleQueue()
        # Guards the fields below it; notified when any changes.
        self._changed: threading.Condition = threading.Condition()
        self._revision: int = 0
        # Set once stdout ended and the exit below was recorded.
        self._ended: bool = False
        # trnrund's exit code, or None if it closed stdout without exiting, and its stderr.
        self._exit_code: int | None = None
        self._diagnostics: str = ""
        # Set once the caller ends the process, so its exit is not an error.
        self._expect_exit: bool = False
        try:
            self._popen: subprocess.Popen[str] = subprocess.Popen(
                [trnrund_path, *args],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except FileNotFoundError as error:
            hint = "Run 'nimble deploy' in components/trnrund, or pass trnrund_path=."
            raise FileNotFoundError(f"trnrund executable not found: {trnrund_path}. {hint}") from error
        self._reader: threading.Thread = threading.Thread(target=self._read, name="trnrund-stdout", daemon=True)
        self._reader.start()

    # -----------------------------------------------------------------
    # Reading stdout
    # -----------------------------------------------------------------
    def _read(self) -> None:
        """Dispatch every stdout line until it ends, record the exit, then wake every waiter."""
        stdout = self._popen.stdout
        try:
            if stdout is not None:
                for line in stdout:
                    self._dispatch(line)
        except (OSError, ValueError):
            pass  # Closed by close(); the daemon is ending either way.
        finally:
            # None if trnrund closed stdout without exiting; stderr is read only once it exited.
            exit_code, diagnostics = None, ""
            with suppress(subprocess.TimeoutExpired, OSError, ValueError):
                exit_code = self._popen.wait(_EXIT_WAIT)
                if self._popen.stderr is not None:
                    diagnostics = self._popen.stderr.read().strip()
            with self._changed:
                self._exit_code, self._diagnostics = exit_code, diagnostics
                self._ended = True
                self._changed.notify_all()
            self._replies.put(None)

    def _dispatch(self, line: str) -> None:
        """Route one stdout line to its request or to change waiters; other lines are ignored."""
        try:
            decoded = cast("object", json.loads(line))
        except json.JSONDecodeError:
            return
        if not isinstance(decoded, dict):
            return
        message = cast("dict[str, object]", decoded)
        if "event" in message:
            revision = message.get("revision")
            if message["event"] == "changed" and isinstance(revision, int):
                with self._changed:
                    self._revision = max(self._revision, revision)
                    self._changed.notify_all()
        elif isinstance(message.get("ok"), bool):
            self._replies.put(message)

    # -----------------------------------------------------------------
    # Requests and notifications
    # -----------------------------------------------------------------
    def request(self, request: dict[str, object], timeout: float | None = None) -> dict[str, object]:
        """Send one request and return its reply.

        Raises RequestRejectedError if trnrund rejects it, TimeoutError if no
        reply arrives within ``timeout`` seconds (by default the instance's
        request timeout), ClosedError once it was closed or exited with code
        0, and DaemonExitedError if it exited otherwise. A request that timed out is abandoned,
        though trnrund may still carry it out; its late reply is skipped.
        """
        timeout = self._request_timeout if timeout is None else timeout
        with self._request_lock:
            stdin = self._popen.stdin
            if stdin is None or stdin.closed:
                raise ClosedError("trnrund is closed")
            self._next_id += 1
            request_id = self._next_id
            # A failed write means trnrund ended or close() closed stdin; the reply loop reports which.
            with suppress(OSError, ValueError):
                _ = stdin.write(json.dumps({"id": request_id, **request}, ensure_ascii=False) + "\n")
                stdin.flush()
            deadline = time.monotonic() + timeout
            while True:
                try:
                    reply = self._replies.get(timeout=max(deadline - time.monotonic(), 0))
                except queue.Empty:
                    raise TimeoutError(f"trnrund did not answer {request.get('cmd')!r} within {timeout} s") from None
                if reply is None:
                    self._replies.put(None)  # Later requests also find the end.
                    raise self._exit_error()
                if reply.get("id") == request_id:
                    break
                # Otherwise it answers an earlier request that timed out.
        if reply["ok"] is not True:
            raise RequestRejectedError(reply.get("error", "trnrund rejected the request"))
        return reply

    def wait_for_changes(self, after_revision: int, timeout: float | None = None) -> bool:
        """Block until trnrund announces a revision after ``after_revision``; return False on timeout.

        Once trnrund has ended with nothing newer, raises ClosedError after a
        clean exit or close(), and DaemonExitedError otherwise; everything it
        saved is readable by then. Safe from any thread.
        """
        with self._changed:
            if not self._changed.wait_for(lambda: self._revision > after_revision or self._ended, timeout):
                return False
            if self._revision > after_revision:
                return True
            raise self._exit_error()

    # -----------------------------------------------------------------
    # Exit
    # -----------------------------------------------------------------
    def wait(self, timeout: float | None = None) -> bool:
        """Wait for trnrund to exit by itself, as after shutdown, then close it.

        Returns False, leaving it running, if ``timeout`` seconds pass first.
        Raises DaemonExitedError, with its diagnostics, if it exited with an
        error.
        """
        try:
            code = self._popen.wait(timeout)
        except subprocess.TimeoutExpired:
            return False
        self.close()
        if code:
            raise DaemonExitedError(code, self._diagnostics)  # Recorded by the reader, which close() joined.
        return True

    def close(self) -> None:
        """Close stdin, which interrupts unfinished runs, and wait for trnrund to exit.

        A trnrund still running after ``_CLOSE_WAIT`` seconds is killed, and
        trnrund's own job object kills its runs with it, so closing never hangs. Safe
        to call again, after wait(), or after trnrund crashed.
        """
        with self._changed:
            self._expect_exit = True
        stdin = self._popen.stdin
        if stdin is not None:
            # A crashed trnrund leaves an unsent request whose flush fails; the stream is closed regardless.
            with suppress(OSError):
                stdin.close()
        try:
            _ = self._popen.wait(_CLOSE_WAIT)
        except subprocess.TimeoutExpired:
            self._popen.kill()
            _ = self._popen.wait()
        self._reader.join(_EXIT_WAIT)
        if self._reader.is_alive():
            # Its blocked read holds stdout's lock, so closing stdout would hang too; the daemon thread is left.
            return
        for stream in (self._popen.stdout, self._popen.stderr):
            if stream is not None:
                with suppress(OSError):
                    stream.close()

    def _exit_error(self) -> ClosedError | DaemonExitedError:
        """Return why trnrund no longer answers, once the reader thread recorded its end."""
        with self._changed:
            if self._exit_code == 0 or self._expect_exit:
                return ClosedError("trnrund is closed")
            return DaemonExitedError(self._exit_code, self._diagnostics)
