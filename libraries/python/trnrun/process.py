"""The trnrund process: start it, exchange JSON lines with it, and report its exit."""

import json
import subprocess
from contextlib import suppress
from pathlib import Path

from .job import assign_to_job

DEFAULT_EXECUTABLE = Path(__file__).parent / "bin" / "trnrund.exe"


def _cli_args(
    *,
    database_path: str | Path,
    max_concurrent: int | None,
    trnrun_path: str | Path | None,
    overwrite: bool,
) -> list[str]:
    """Return trnrund options with absolute paths; None keeps the daemon's default."""
    if type(overwrite) is not bool:
        raise TypeError(f"overwrite must be True or False, got {overwrite!r}")
    args = [f"--database:{Path(database_path).absolute()}", f"--overwrite:{str(overwrite).lower()}"]
    if max_concurrent is not None:
        args.append(f"--maxConcurrent:{max_concurrent}")
    if trnrun_path is not None:
        args.append(f"--trnrun:{Path(trnrun_path).absolute()}")
    return args


def _parse_reply(line: str) -> dict[str, object]:
    """Decode one reply line, which must be a JSON object with a boolean ok."""
    reply: object = json.loads(line)
    if isinstance(reply, dict) and isinstance(reply.get("ok"), bool):
        return reply
    raise RuntimeError(f"Invalid trnrund reply: {line.strip()}")


class DaemonProcess:
    """A running trnrund answering one JSON request per line, in order.

    stderr is captured rather than shown: trnrund writes to it only before a
    fatal exit, and that text is added to the RuntimeError reporting the exit.
    Use one thread per instance; requests are synchronous.
    """

    def __init__(
        self,
        *,
        database_path: str | Path,
        max_concurrent: int | None,
        trnrun_path: str | Path | None,
        overwrite: bool,
        executable: str | Path,
    ) -> None:
        """Start trnrund without a console window, in the kill-on-close job; do not wait for it."""
        args = _cli_args(
            database_path=database_path,
            max_concurrent=max_concurrent,
            trnrun_path=trnrun_path,
            overwrite=overwrite,
        )
        self._expect_exit: bool = False
        self._diagnostics: str | None = None
        try:
            self._popen: subprocess.Popen[str] = subprocess.Popen(
                [executable, *args],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                encoding="utf-8",
                errors="replace",
                creationflags=subprocess.CREATE_NO_WINDOW,
            )
        except FileNotFoundError as error:
            raise FileNotFoundError(
                f"trnrund executable not found: {executable}. "
                "Run 'nimble deploy' in components/trnrund, or pass executable=.",
            ) from error
        _ = assign_to_job(self._popen)

    def request(self, request: dict[str, object]) -> dict[str, object]:
        """Send one request and return its reply; raise ValueError if rejected."""
        stdin, stdout = self._popen.stdin, self._popen.stdout
        if stdin is None or stdout is None or stdin.closed:
            raise RuntimeError("trnrund is closed")
        try:
            _ = stdin.write(json.dumps(request, ensure_ascii=False) + "\n")
            stdin.flush()
        except OSError:
            raise self._exit_error() from None
        # shortcut: replies can block; add timeouts if hang recovery is needed.
        line = stdout.readline()
        if not line:
            raise self._exit_error()
        reply = _parse_reply(line)
        if not reply["ok"]:
            raise ValueError(reply.get("error", "trnrund rejected the request"))
        return reply

    def check(self) -> None:
        """Raise RuntimeError if trnrund exited before wait() or close()."""
        if not self._expect_exit and self._popen.poll() is not None:
            raise self._exit_error()

    def wait(self) -> None:
        """Wait for trnrund to exit by itself, as after shutdown, then close it.

        Raises RuntimeError, with its diagnostics, if it exited with an error.
        """
        self._expect_exit = True
        error = self._exit_error() if self._popen.wait() else None
        self.close()
        if error is not None:
            raise error

    def close(self) -> None:
        """Close stdin, which cancels unfinished runs, and wait for trnrund to exit.

        Safe to call again, after wait(), or after trnrund crashed.
        """
        self._expect_exit = True
        for stream in (self._popen.stdin, self._popen.stdout, self._popen.stderr):
            if stream is not None:
                # A crashed trnrund leaves an unsent request whose flush fails; the
                # stream is closed regardless.
                with suppress(OSError):
                    stream.close()
        _ = self._popen.wait()

    def _exit_error(self) -> RuntimeError:
        """Describe how trnrund exited, waiting for it if needed."""
        code = self._popen.wait()
        if self._diagnostics is None:
            stderr = self._popen.stderr
            self._diagnostics = "" if stderr is None or stderr.closed else stderr.read().strip()
        message = f"trnrund exited with code {code}"
        return RuntimeError(f"{message}: {self._diagnostics}" if self._diagnostics else message)
