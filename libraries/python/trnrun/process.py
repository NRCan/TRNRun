"""Interactive `trnrunq.exe` child process.

Owns the queue process and its two pipes: JSON requests go in one line at a
time, and queue lifecycle events plus merged child output come back the same
way. This module knows the queue's command line and framing, and nothing about
simulations.

Reads and writes block. The caller must drain stdout regularly; leaving it
unread can fill the pipe and stall the queue.
"""

from __future__ import annotations

import contextlib
import json
import subprocess
from pathlib import Path
from typing import IO, Final

from trnrun.job import assign_to_job

CREATE_NO_WINDOW: Final[int] = getattr(subprocess, "CREATE_NO_WINDOW", 0)


class QueueProcess:
    """One running `trnrunq.exe` and the pipes used to drive it.

    Parameters
    ----------
    executable : str or Path
        Path to the queue executable to spawn.
    max_concurrent : int
        Maximum simultaneous runners, passed as `--maxConcurrent`.
    """

    def __init__(self, executable: str | Path, max_concurrent: int) -> None:
        """Spawn the queue process and adopt it into the kill-on-close job."""
        if max_concurrent < 1:
            raise ValueError("max_concurrent must be at least 1")

        executable = Path(executable)
        if not executable.is_file():
            raise FileNotFoundError(f"TRNRun queue executable not found: {executable}")

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
            bufsize=1,
            creationflags=CREATE_NO_WINDOW,
        )
        _ = assign_to_job(self._process)
        self._stdin: IO[str] = self._require_stream(self._process.stdin, "stdin")
        self._stdout: IO[str] = self._require_stream(self._process.stdout, "stdout")

    def send(self, request: dict[str, object]) -> None:
        """Write one request as a single JSON line."""
        _ = self._stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
        self._stdin.flush()

    def read_line(self) -> str | None:
        """Block for the next queue stdout line, or return None at EOF."""
        return self._stdout.readline() or None

    def close(self) -> None:
        """Close queue input, ending submission and starting its drain."""
        with contextlib.suppress(BrokenPipeError, OSError, ValueError):
            self._stdin.close()

    def wait(self) -> int:
        """Wait for the queue process to exit and return its exit code."""
        return self._process.wait()

    @staticmethod
    def _require_stream(stream: IO[str] | None, name: str) -> IO[str]:
        """Return a configured queue stream."""
        if stream is None:
            raise RuntimeError(f"queue {name} is unavailable")
        return stream
