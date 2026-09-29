"""Interactive `trnrunq.exe` process with background stdout reading."""

from __future__ import annotations

import contextlib
import json
import subprocess
from _thread import LockType
from collections.abc import Callable
from pathlib import Path
from threading import Event, Lock, Thread, current_thread
from types import TracebackType
from typing import IO, Final, Self

from trnrun.job import assign_to_job

CREATE_NO_WINDOW: Final[int] = getattr(subprocess, "CREATE_NO_WINDOW", 0)
SHUTDOWN_TIMEOUT: Final[float] = 5.0


class QueueProcess:
    """Run a queue and forward stdout lines on a background thread.

    The owner controls the lifetime; the queue and output callback are assumed
    to stay healthy until shutdown. Callbacks may run before construction
    returns and must return promptly. Shutdown must not be concurrent or
    reentrant, and callers must not hold locks needed by the callback.
    """

    def __init__(
        self,
        executable: str | Path,
        max_concurrent: int,
        on_output: Callable[[str], None],
    ) -> None:
        """Spawn the queue, assign its job, and start reading UTF-8 output."""
        if type(max_concurrent) is not int or max_concurrent < 1:
            raise ValueError("max_concurrent must be an integer of at least 1")

        executable = Path(executable).absolute()
        if not executable.is_file():
            raise FileNotFoundError(f"TRNRun queue executable not found: {executable}")

        self._on_output: Callable[[str], None] = on_output
        self._write_lock: LockType = Lock()
        self._closing: Event = Event()
        process: subprocess.Popen[str] = subprocess.Popen(
            [str(executable), f"--maxConcurrent:{max_concurrent}"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            encoding="utf-8",
            errors="replace",
            creationflags=CREATE_NO_WINDOW,
        )
        try:
            _ = assign_to_job(process)
            if process.stdin is None or process.stdout is None:
                raise RuntimeError("TRNRun queue pipes are unavailable")  # noqa: TRY301 - use the same startup cleanup

            self._process: subprocess.Popen[str] = process
            self._stdin: IO[str] = process.stdin
            self._reader: Thread = Thread(
                target=self._read_output,
                args=(process.stdout,),
                name="trnrunq-reader",
                daemon=True,
            )
            self._reader.start()
        except BaseException:
            # Best-effort cleanup must preserve the original startup exception.
            with contextlib.suppress(Exception):
                process.kill()
            with contextlib.suppress(Exception):
                _ = process.wait(timeout=SHUTDOWN_TIMEOUT)
            for stream in (process.stdin, process.stdout):
                if stream is not None:
                    with contextlib.suppress(Exception):
                        stream.close()
            raise

    def __enter__(self) -> Self:
        """Return this queue for context-managed cleanup."""
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Stop the queue when leaving the context."""
        self.shutdown()

    @property
    def is_alive(self) -> bool:
        """Return whether the queue process is running."""
        return self._process.poll() is None

    def send(self, request: dict[str, object]) -> None:
        """Write and flush one strict JSON line without interleaving senders."""
        line = json.dumps(request, separators=(",", ":"), allow_nan=False) + "\n"
        if self._closing.is_set():
            raise RuntimeError("Cannot send after queue closure has started")
        with self._write_lock:
            if self._closing.is_set():
                raise RuntimeError("Cannot send after queue closure has started")
            _ = self._stdin.write(line)
            self._stdin.flush()

    def shutdown(self) -> None:
        """Kill/reap the queue, close stdin, and join its reader.

        Each wait has a five-second timeout; incomplete cleanup can be retried.
        Only the reader closes stdout, avoiding its cross-thread stream lock.
        """
        self._closing.set()
        # Kill before taking the write lock to unblock a full stdin pipe.
        if self.is_alive:
            self._process.kill()
        _ = self._process.wait(timeout=SHUTDOWN_TIMEOUT)

        if not self._write_lock.acquire(timeout=SHUTDOWN_TIMEOUT):
            raise TimeoutError("Timed out waiting for queue stdin writer")
        try:
            with contextlib.suppress(OSError):
                self._stdin.close()
        finally:
            self._write_lock.release()

        if current_thread() is not self._reader:
            self._reader.join(timeout=SHUTDOWN_TIMEOUT)
            if self._reader.is_alive():
                raise TimeoutError("Timed out waiting for queue stdout reader")

    def _read_output(self, stdout: IO[str]) -> None:
        """Forward lines, including trailing newlines, until the queue closes."""
        try:
            for line in iter(stdout.readline, ""):
                self._on_output(line)
        finally:
            self._closing.set()
            stdout.close()
