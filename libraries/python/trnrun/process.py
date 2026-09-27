"""Interactive `trnrunq.exe` child process.

Owns the queue process and its two pipes: JSON requests go in one line at a
time, and queue lifecycle events plus merged child output come back the same
way. This module knows the queue's command line and framing, and nothing about
simulations.

Writes block. Stdout is consumed by a background thread that hands each line to
an `on_line` callback, because the queue serializes every worker's output
through one lock: a full stdout pipe stalls all concurrent runs, not just the
caller's. The callback therefore runs on the reader thread and must not block
or raise; the reader guards against both so draining can never stop.
"""

from __future__ import annotations

import contextlib
import json
import logging
import subprocess
import threading
from collections.abc import Callable
from pathlib import Path
from typing import IO, Final

from trnrun.job import assign_to_job

logger = logging.getLogger(__name__)

CREATE_NO_WINDOW: Final[int] = getattr(subprocess, "CREATE_NO_WINDOW", 0)

# Bounds shutdown when the reader cannot observe EOF; it is a daemon thread.
_READER_JOIN_TIMEOUT: Final[float] = 5.0


class QueueProcess:
    """One running `trnrunq.exe` and the pipes used to drive it.

    Parameters
    ----------
    executable : str or Path
        Path to the queue executable to spawn.
    max_concurrent : int
        Positive integer limiting simultaneous runners (`--maxConcurrent`).
    on_line : callable
        Invoked with each stdout line, on the reader thread, in order.
    on_eof : callable
        Invoked once after stdout closes, on the reader thread.
    """

    def __init__(
        self,
        executable: str | Path,
        max_concurrent: int,
        on_line: Callable[[str], None],
        on_eof: Callable[[], None],
    ) -> None:
        """Spawn the queue process, adopt it into the kill-on-close job, and start reading."""
        if max_concurrent < 1:
            raise ValueError("max_concurrent must be at least 1")

        executable = Path(executable).absolute()
        if not executable.is_file():
            raise FileNotFoundError(f"TRNRun queue executable not found: {executable}")

        self._on_line: Callable[[str], None] = on_line
        self._on_eof: Callable[[], None] = on_eof

        self._process: subprocess.Popen[str] = subprocess.Popen(
            [
                str(executable),
                f"--maxConcurrent:{max_concurrent}",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            creationflags=CREATE_NO_WINDOW,
        )
        _ = assign_to_job(self._process)
        self._stdin: IO[str] = self._require_stream(self._process.stdin, "stdin")
        self._stdout: IO[str] = self._require_stream(self._process.stdout, "stdout")

        self._reader: threading.Thread = threading.Thread(
            target=self._consume_stdout,
            name="trnrunq-stdout",
            daemon=True,
        )
        self._reader.start()

    def send(self, request: dict[str, object]) -> None:
        """Encode a request as strict JSON, then write and flush one line."""
        _ = self._stdin.write(json.dumps(request, separators=(",", ":"), allow_nan=False) + "\n")
        self._stdin.flush()

    def shutdown(self) -> None:
        """Kill and reap the queue, then close its pipes without draining output."""
        try:
            # Kill before waiting or closing pipes: unread stdout may be full.
            self._process.kill()
            _ = self._process.wait()
        finally:
            with contextlib.suppress(OSError):
                self._stdin.close()
            with contextlib.suppress(OSError):
                self._stdout.close()
            self._reader.join(timeout=_READER_JOIN_TIMEOUT)

    def _consume_stdout(self) -> None:
        """Hand every stdout line to the callback, always signalling EOF exactly once."""
        try:
            for line in self._stdout:
                try:
                    self._on_line(line)
                except Exception:  # a callback bug must not stop draining
                    logger.exception("queue line callback failed; continuing to drain stdout")
        except (OSError, ValueError):
            pass  # shutdown closed stdout underneath us
        finally:
            try:
                self._on_eof()
            except Exception:  # EOF callback bugs must not escape the thread
                logger.exception("queue EOF callback failed")

    @staticmethod
    def _require_stream(stream: IO[str] | None, name: str) -> IO[str]:
        """Return a configured queue stream."""
        if stream is None:
            raise RuntimeError(f"queue {name} is unavailable")
        return stream
