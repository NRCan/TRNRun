"""The trnrund process: start it, exchange JSON lines with it, and report its exit."""

import json
import logging
import queue
import subprocess
import threading
import time
from contextlib import suppress
from pathlib import Path
from typing import cast

from .job import assign_to_job

logger = logging.getLogger(__name__)

_EXIT_WAIT = 10.0  # Seconds to wait for trnrund to exit once its stdout ended.
_CLOSE_WAIT = 10.0  # Seconds trnrund gets to save interrupted runs and exit once stdin is closed.


class DaemonProcess:
    """A running trnrund, read by a background thread.

    The thread sorts each stdout line: replies go to the waiting request,
    matched by ``id``, and ``changed`` notifications wake ``wait_for_change``.
    trnrund's stdout ends only after its final changes are saved, so the end
    of stdout is how a crashed daemon is noticed. stderr is captured rather
    than shown: trnrund writes to it only before a fatal exit, and that text
    is added to the RuntimeError reporting the exit.

    Requests are serialized, so any thread may send one.
    """

    def __init__(self, trnrund_path: str | Path, args: list[str], *, request_timeout: float) -> None:
        """Start trnrund with ``args`` without a console window, in the kill-on-close job; do not wait for it."""
        self._request_timeout: float = request_timeout
        # Serializes requests, so replies arrive in the order they are awaited.
        self._request_lock: threading.Lock = threading.Lock()
        self._next_id: int = 0
        # Replies read from stdout; None marks its end.
        self._replies: queue.SimpleQueue[dict[str, object] | None] = queue.SimpleQueue()
        # Guards _revision and _ended; notified when either changes.
        self._changed: threading.Condition = threading.Condition()
        self._revision: int = 0
        self._ended: bool = False
        # Set once the caller ends the process, so its exit is not an error.
        self._expect_exit: bool = False
        # Guards _diagnostics, read once from stderr.
        self._exit_lock: threading.Lock = threading.Lock()
        self._diagnostics: str | None = None
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
        _ = assign_to_job(self._popen)
        self._reader: threading.Thread = threading.Thread(target=self._read, name="trnrund-stdout", daemon=True)
        self._reader.start()

    # -----------------------------------------------------------------
    # Reading stdout
    # -----------------------------------------------------------------
    def _read(self) -> None:
        """Dispatch every stdout line until it ends, then wake every waiter."""
        stdout = self._popen.stdout
        try:
            if stdout is not None:
                for line in stdout:
                    self._dispatch(line)
        except (OSError, ValueError):
            pass  # Closed by close(); the daemon is ending either way.
        finally:
            with self._changed:
                self._ended = True
                self._changed.notify_all()
            self._replies.put(None)

    def _dispatch(self, line: str) -> None:
        """Route one stdout line to its request or to change waiters."""
        try:
            decoded = cast("object", json.loads(line))
        except json.JSONDecodeError:
            logger.warning("Ignoring a trnrund line that is not JSON: %r", line)
            return
        if not isinstance(decoded, dict):
            logger.warning("Ignoring a trnrund line that is not an object: %r", line)
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
        else:
            logger.warning("Ignoring an unknown trnrund line: %r", line)

    # -----------------------------------------------------------------
    # Requests and notifications
    # -----------------------------------------------------------------
    def request(self, request: dict[str, object], timeout: float | None = None) -> dict[str, object]:
        """Send one request and return its reply.

        Raises ValueError if trnrund rejects it, TimeoutError if no reply
        arrives within ``timeout`` seconds (by default the instance's request
        timeout), and RuntimeError if trnrund has exited.
        """
        timeout = self._request_timeout if timeout is None else timeout
        with self._request_lock:
            stdin = self._popen.stdin
            if stdin is None or stdin.closed:
                raise RuntimeError("trnrund is closed")
            self._next_id += 1
            request_id = self._next_id
            try:
                _ = stdin.write(json.dumps({"id": request_id, **request}, ensure_ascii=False) + "\n")
                stdin.flush()
            except OSError:
                raise self._exit_error() from None
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
            raise ValueError(reply.get("error", "trnrund rejected the request"))
        return reply

    def wait_for_change(self, after_revision: int, timeout: float | None = None) -> bool:
        """Block until trnrund announces a revision after ``after_revision``, or its stdout ends.

        Returns False if ``timeout`` seconds pass first. Safe from any thread.
        """
        with self._changed:
            return self._changed.wait_for(lambda: self._revision > after_revision or self._ended, timeout)

    # -----------------------------------------------------------------
    # Exit
    # -----------------------------------------------------------------
    def exit_error(self) -> RuntimeError | None:
        """Return how trnrund exited if it ended before wait() or close(), else None.

        Its stdout ends only after its final changes are saved, so everything
        it saved is readable once this returns an error.
        """
        with self._changed:
            ended = self._ended
        if ended and not self._expect_exit:
            return self._exit_error()
        return None

    def wait(self, timeout: float | None = None) -> bool:
        """Wait for trnrund to exit by itself, as after shutdown, then close it.

        Returns False, leaving it running, if ``timeout`` seconds pass first.
        Raises RuntimeError, with its diagnostics, if it exited with an error.
        """
        self._expect_exit = True
        try:
            code = self._popen.wait(timeout)
        except subprocess.TimeoutExpired:
            return False
        error = self._exit_error() if code else None
        self.close()
        if error is not None:
            raise error
        return True

    def close(self) -> None:
        """Close stdin, which interrupts unfinished runs, and wait for trnrund to exit.

        A trnrund still running after ``_CLOSE_WAIT`` seconds is killed, and
        its job object kills its runs with it, so closing never hangs. Safe
        to call again, after wait(), or after trnrund crashed.
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
            logger.warning("trnrund did not exit within %s s of closing stdin; killing it", _CLOSE_WAIT)
            self._popen.kill()
            _ = self._popen.wait()
        if threading.current_thread() is not self._reader:
            self._reader.join(_EXIT_WAIT)
            if self._reader.is_alive():
                # Its blocked read holds stdout's lock, so closing stdout would hang too; the daemon thread is left.
                logger.warning("trnrund's stdout is still open after it exited; leaving it to the reader thread")
                return
        for stream in (self._popen.stdout, self._popen.stderr):
            if stream is not None:
                with suppress(OSError):
                    stream.close()

    def _exit_error(self) -> RuntimeError:
        """Describe how trnrund exited, waiting briefly for it if needed."""
        try:
            code = self._popen.wait(_EXIT_WAIT)
        except subprocess.TimeoutExpired:
            return RuntimeError("trnrund closed its output but did not exit")
        with self._exit_lock:
            if self._diagnostics is None:
                stderr = self._popen.stderr
                self._diagnostics = "" if stderr is None or stderr.closed else stderr.read().strip()
        message = f"trnrund exited with code {code}"
        return RuntimeError(f"{message}: {self._diagnostics}" if self._diagnostics else message)
