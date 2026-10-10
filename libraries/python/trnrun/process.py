"""Interactive `trnrund.exe` process answering one JSON request at a time."""

from __future__ import annotations

import contextlib
import json
import subprocess
from _thread import LockType
from pathlib import Path
from threading import Lock
from typing import IO, Final

from trnrun.job import assign_to_job

CREATE_NO_WINDOW: Final[int] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
SHUTDOWN_TIMEOUT: Final[float] = 5.0


def _require_pipe(stream: IO[str] | None) -> IO[str]:
    """Return a daemon pipe, rejecting a missing stream."""
    if stream is None:
        raise RuntimeError("TRNRun daemon pipes are unavailable")
    return stream


class DaemonProcess:
    """Manage a TRNRun daemon through synchronous JSON request/reply exchanges.

    Parameters
    ----------
    executable : str or Path
        Path to the ``trnrund.exe`` daemon.
    trnrun_path : str or Path
        Path to the ``trnrun.exe`` runner used by the daemon.
    max_concurrent : int
        Maximum simultaneous runs, validated by the daemon.

    Raises
    ------
    FileNotFoundError
        If either executable is missing.
    RuntimeError
        If the daemon rejects its configuration or exits during startup.

    Notes
    -----
    Construction waits for the daemon to acknowledge ``ready`` after successful
    startup. Requests are serialized
    by a lock so concurrent callers never receive each other's replies. A rejected
    request raises ``ValueError``; daemon exit or shutdown raises ``RuntimeError``.

    The owner must call ``shutdown()`` to kill and reap the daemon and close its
    pipes, or ``wait()`` once the daemon acknowledged a ``shutdown`` request.
    The daemon's job object terminates its runners when the daemon exits.
    Process waits have a five-second timeout, and incomplete cleanup can be
    retried. Shutdown may interrupt a request, but shutdown calls must not be
    concurrent or reentrant.
    """

    def __init__(
        self,
        executable: str | Path,
        trnrun_path: str | Path,
        max_concurrent: int,
    ) -> None:
        """Spawn the daemon and wait until it serves requests."""
        executable = Path(executable).absolute()
        if not executable.is_file():
            raise FileNotFoundError(f"TRNRun daemon executable not found: {executable}")

        trnrun_path = Path(trnrun_path).absolute()
        if not trnrun_path.is_file():
            raise FileNotFoundError(f"TRNRun executable not found: {trnrun_path}")

        self._lock: LockType = Lock()
        self._closing: bool = False
        self._process: subprocess.Popen[str] = subprocess.Popen(
            [str(executable), f"--trnrun:{trnrun_path}", f"--maxConcurrent:{max_concurrent}"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            # Only startup and fatal diagnostics; runner output never reaches it.
            stderr=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            creationflags=CREATE_NO_WINDOW,
        )
        try:
            self._stdin: IO[str] = _require_pipe(self._process.stdin)
            self._stdout: IO[str] = _require_pipe(self._process.stdout)
            self._stderr: IO[str] = _require_pipe(self._process.stderr)
            _ = assign_to_job(self._process)
            # Acknowledged only after successful daemon initialization.
            _ = self.request({"cmd": "ready"})
        except BaseException:
            # Best-effort cleanup must preserve the original startup exception.
            with contextlib.suppress(Exception):
                self.shutdown()
            raise

    def request(self, request: dict[str, object]) -> dict[str, object]:
        """Send one strict JSON request and return its successful reply."""
        line = json.dumps(request, separators=(",", ":"), allow_nan=False) + "\n"
        reply_line = self._exchange(line)

        reply: dict[str, object] = json.loads(reply_line)  # pyright: ignore[reportAny]
        if reply.get("ok") is not True:
            raise ValueError(reply.get("error", f"TRNRun daemon sent an invalid reply: {reply_line.strip()}"))
        return reply

    def shutdown(self) -> None:
        """Kill and reap the daemon, then close its pipes."""
        self._closing = True
        # Kill before taking the lock, so a request blocked on its reply sees EOF.
        # Popen.kill is a no-op once the daemon has exited.
        self._process.kill()
        _ = self._process.wait(timeout=SHUTDOWN_TIMEOUT)
        self._close_pipes()

    def wait(self, timeout: float | None = None) -> None:
        """Wait for the daemon to exit on its own, then close its pipes.

        Use after the daemon acknowledged a ``shutdown`` request. Later requests
        raise ``RuntimeError``. On ``subprocess.TimeoutExpired`` the daemon keeps
        running and ``shutdown()`` can still kill it.
        """
        self._closing = True
        _ = self._process.wait(timeout=timeout)
        self._close_pipes()

    def _close_pipes(self) -> None:
        """Close the daemon pipes under the request lock."""
        with self._lock:
            for stream in (self._process.stdin, self._process.stdout, self._process.stderr):
                if stream is not None:
                    with contextlib.suppress(OSError):
                        stream.close()

    def _exchange(self, line: str) -> str:
        """Write one request line and read its reply under the transport lock."""
        with self._lock:
            if self._closing:
                raise RuntimeError("Cannot send after daemon closure has started")
            try:
                _ = self._stdin.write(line)
                self._stdin.flush()
                reply_line = self._stdout.readline()
            except BrokenPipeError as exc:
                raise RuntimeError(self._exit_message()) from exc
            if not reply_line:
                raise RuntimeError(self._exit_message())
            return reply_line

    def _exit_message(self) -> str:
        """Describe a broken pipe or EOF under the request lock, including diagnostics."""
        if self._closing:
            return "TRNRun daemon was shut down"
        try:
            # Reap before reading stderr, so diagnostics have reached EOF.
            _ = self._process.wait(timeout=SHUTDOWN_TIMEOUT)
            diagnostics = self._stderr.read().strip()
        except (OSError, ValueError, subprocess.TimeoutExpired):
            diagnostics = ""
        message = f"TRNRun daemon exited with code {self._process.returncode}"
        return f"{message}: {diagnostics}" if diagnostics else message
