"""Start trnrund, submit runs to it, and know when its database changed."""

import sqlite3
from collections.abc import Sequence
from pathlib import Path
from tempfile import TemporaryDirectory
from types import TracebackType
from typing import Self, cast

from .database import connect
from .process import DaemonProcess
from .settings import SimulationSettings

DEFAULT_TRNRUN = Path(__file__).parent / "bin" / "trnrun.exe"
DEFAULT_TRNRUND = Path(__file__).parent / "bin" / "trnrund.exe"
DEFAULT_REQUEST_TIMEOUT = 60.0


class Daemon:
    """A running trnrund: submit runs, and wait until its database changes.

    trnrund saves every run and log to SQLite; read it with ``connect()`` and
    ``read_changes`` or plain SQL. Every method is thread-safe.

    Attributes
    ----------
    database_path : Path
        The database trnrund opened.
    session_id : int
        This daemon's session, recorded on every run it adds.
    start_revision, start_log_id : int
        Positions when the daemon started; read from them to see only its changes.
    """

    def __init__(
        self,
        database_path: str | Path | None = None,
        *,
        max_concurrent: int | None = None,
        trnrund_path: str | Path = DEFAULT_TRNRUND,
        trnrun_path: str | Path = DEFAULT_TRNRUN,
        request_timeout: float = DEFAULT_REQUEST_TIMEOUT,
    ) -> None:
        """Start trnrund and wait until it is ready.

        Without ``database_path`` the runs go to a temporary database that
        ``close()`` deletes; an existing database keeps its runs, and new ones
        continue their numbering. ``max_concurrent`` defaults to the CPU count
        minus one. Raises DaemonExitedError if trnrund fails to start, and
        TimeoutError for any request unanswered within ``request_timeout`` seconds.
        """
        self._temporary: TemporaryDirectory[str] | None = None
        if database_path is None:
            self._temporary = TemporaryDirectory(prefix="trnrun-", ignore_cleanup_errors=True)
            database_path = Path(self._temporary.name) / "runs.sqlite3"
        args = [f"--trnrun:{Path(trnrun_path).absolute()}", f"--database:{Path(database_path).absolute()}"]
        if max_concurrent is not None:
            args.append(f"--maxConcurrent:{max_concurrent}")
        process: DaemonProcess | None = None
        try:
            process = DaemonProcess(trnrund_path, args, request_timeout=request_timeout)
            ready = process.request({"cmd": "ready"})
        except BaseException:
            if process is not None:
                process.close()
            if self._temporary is not None:
                self._temporary.cleanup()
            raise
        self._process: DaemonProcess = process
        self.database_path: Path = Path(cast("str", ready["databasePath"]))
        self.session_id: int = cast("int", ready["sessionId"])
        self.start_revision: int = cast("int", ready["revision"])
        self.start_log_id: int = cast("int", ready["logId"])

    def add(
        self,
        deck_file: str | Path,
        trnrun_args: Sequence[str] | SimulationSettings = (),
        *,
        label: str | None = None,
    ) -> int:
        """Submit a deck and return its run ID once saved, not finished; raise RequestRejectedError if refused."""
        args = trnrun_args.to_cli_args() if isinstance(trnrun_args, SimulationSettings) else list(trnrun_args)
        request: dict[str, object] = {"cmd": "add", "deckFile": str(Path(deck_file).absolute()), "trnrunArgs": args}
        if label is not None:
            request["label"] = label
        return cast("int", self._process.request(request)["runId"])

    def cancel(self, run_id: int) -> None:
        """Stop a queued or running run, leaving a finished one unchanged; raise RequestRejectedError for an unknown ID."""
        _ = self._process.request({"cmd": "cancel", "runId": run_id})

    def shutdown(self, *, cancel_running: bool = False, timeout: float | None = None) -> None:
        """Cancel queued runs, let running ones finish, and wait for trnrund to exit.

        ``cancel_running`` cancels running runs too; any still running after
        ``timeout`` seconds are interrupted as by ``close()``. Raises
        DaemonExitedError if trnrund exits with an error.
        """
        _ = self._process.request({"cmd": "shutdown", "cancelRunning": cancel_running})
        if not self._process.wait(timeout):
            self._process.close()

    def connect(self) -> sqlite3.Connection:
        """Open the daemon's database read-only; see ``trnrun.database.connect``."""
        return connect(self.database_path)

    def wait_for_change(self, after_revision: int, timeout: float | None = None) -> bool:
        """Block until trnrund announces a revision after ``after_revision``, then return True.

        Returns False on timeout, or once trnrund has exited after ``shutdown()``
        or ``close()`` with nothing newer. Raises DaemonExitedError instead once
        it has crashed with nothing newer.
        """
        if not self._process.wait_for_change(after_revision, timeout):
            return False
        if self._process.revision > after_revision:
            return True
        error = self._process.exit_error()
        if error is not None:
            raise error
        return False

    def close(self) -> None:
        """Interrupt unfinished runs, stop trnrund, and delete a temporary database; safe to call again."""
        self._process.close()
        if self._temporary is not None:
            self._temporary.cleanup()

    def __enter__(self) -> Self:
        """Return this daemon for use in a with block."""
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Close the daemon when leaving a with block."""
        self.close()
