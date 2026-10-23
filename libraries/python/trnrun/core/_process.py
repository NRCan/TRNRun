"""The trnrund process: start it, exchange JSON lines with it, and report its exit."""

import json
import subprocess
import threading
from contextlib import suppress
from pathlib import Path
from typing import cast

from trnrun.core.errors import ClosedError, DaemonExitedError, ProtocolError, RequestRejectedError

_EXIT_WAIT = 10.0  # Seconds to wait for trnrund to exit once its stdout ended.
_CLOSE_WAIT = 10.0  # Seconds trnrund gets to exit once stdin is closed.


class DaemonProcess:
    """A running trnrund, spoken to on the caller's thread.

    Each request writes one line to stdin and reads one reply line from
    stdout, which must repeat the request's ``id``; trnrund writes nothing
    else there. Its stdout ends only when it exits, so an empty read is how a
    crashed daemon is noticed, at once, without a timeout. stderr is captured
    rather than shown: trnrund writes to it only before a fatal exit, and that
    text is added to the DaemonExitedError reporting the exit.

    A lock serializes requests, so an application's own threads can share one
    daemon; a request that waits on a simulation holds the others back.
    """

    def __init__(self, trnrund_path: str | Path, args: list[str]) -> None:
        """Start trnrund with ``args`` without a console window; do not wait for it."""
        # Reentrant, so close() can run from a request that found a protocol error.
        self._lock: threading.RLock = threading.RLock()
        self._next_id: int = 0
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

    def request(self, request: dict[str, object]) -> dict[str, object]:
        """Send one request and return its reply.

        Raises RequestRejectedError if trnrund rejects it, ClosedError once it
        was closed or exited with code 0, DaemonExitedError if it exited
        otherwise, and ProtocolError, closing it, if it answered with anything
        but this request's reply.
        """
        with self._lock:
            stdin, stdout = self._popen.stdin, self._popen.stdout
            if self._ended or self._expect_exit or stdin is None or stdout is None:
                raise self._exit_error()
            self._next_id += 1
            request_id = self._next_id
            line = ""
            # A failed write or read means trnrund ended or close() ran; its exit tells which.
            with suppress(OSError, ValueError):
                _ = stdin.write(json.dumps({"id": request_id, **request}, ensure_ascii=False) + "\n")
                stdin.flush()
                line = stdout.readline()
            if not line:
                self._record_exit()
                raise self._exit_error()
            try:
                reply = _parse_reply(line, request_id)
            except ProtocolError:
                self.close()  # Every later reply would be out of step.
                raise
        if reply["ok"] is not True:
            raise RequestRejectedError(reply.get("error", "trnrund rejected the request"))
        return reply

    def close(self) -> None:
        """Close stdin, which makes trnrund kill unfinished runs and exit, and wait for it.

        A trnrund still running after ``_CLOSE_WAIT`` seconds is killed, and
        trnrund's own job object kills its runs with it, so closing never
        hangs. Safe to call again, from any thread, or after trnrund crashed.
        """
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
        # A request blocked in another thread now reads the end of stdout and lets go of the lock.
        if not self._lock.acquire(timeout=_EXIT_WAIT):
            return
        try:
            for stream in (self._popen.stdout, self._popen.stderr):
                if stream is not None:
                    with suppress(OSError):
                        stream.close()
        finally:
            self._lock.release()

    def _record_exit(self) -> None:
        """Wait for trnrund once its stdout ended, and keep its exit code and stderr."""
        self._ended = True
        # None if trnrund closed stdout without exiting; stderr is read only once it exited.
        with suppress(subprocess.TimeoutExpired, OSError, ValueError):
            self._exit_code = self._popen.wait(_EXIT_WAIT)
            if self._popen.stderr is not None:
                self._diagnostics = self._popen.stderr.read().strip()

    def _exit_error(self) -> ClosedError | DaemonExitedError:
        """Return why trnrund no longer answers, a fresh error each time."""
        if self._exit_code == 0 or self._expect_exit:
            return ClosedError("trnrund is closed")
        return DaemonExitedError(self._exit_code, self._diagnostics)


def _parse_reply(line: str, request_id: int) -> dict[str, object]:
    """Return the reply ``line`` holds; ProtocolError unless it is the reply to ``request_id``."""
    try:
        decoded = cast("object", json.loads(line))
    except json.JSONDecodeError:
        decoded = None
    if not isinstance(decoded, dict):
        raise ProtocolError(f"trnrund wrote a line that is not a reply: {line.strip()!r}")
    reply = cast("dict[str, object]", decoded)
    if not isinstance(reply.get("ok"), bool) or reply.get("id") != request_id:
        raise ProtocolError(f"trnrund wrote a line that is not the reply to request {request_id}: {line.strip()!r}")
    return reply
