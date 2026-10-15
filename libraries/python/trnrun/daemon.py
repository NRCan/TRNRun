"""Start trnrund, submit runs to it, and follow them through its database."""

from collections.abc import Sequence
from contextlib import ExitStack
from pathlib import Path
from tempfile import TemporaryDirectory
from types import TracebackType
from typing import Self

from .database import Database
from .process import DaemonProcess
from .runs import Changes
from .settings import DaemonSettings, SimulationSettings

DEFAULT_TRNRUN = Path(__file__).parent / "bin" / "trnrun.exe"
DEFAULT_TRNRUND = Path(__file__).parent / "bin" / "trnrund.exe"
DEFAULT_REQUEST_TIMEOUT = 60.0


def _field[T](reply: dict[str, object], key: str, kind: type[T]) -> T:
    """Return a reply field of ``kind``; RuntimeError if trnrund sent something else."""
    value = reply.get(key)
    if not isinstance(value, kind):
        raise RuntimeError(f"trnrund reply has no {kind.__name__} {key!r}: {reply}")  # noqa: TRY004 - a protocol error
    return value


class Daemon:
    """Start trnrund, submit runs to it, and follow them as it saves them.

    trnrund numbers each run and saves every change to its SQLite database,
    and announces each batch of changes on its stdout. ``wait()`` blocks until
    one arrives and returns what changed; ``poll()`` returns it without
    blocking. Both raise once trnrund has exited unexpectedly and everything
    it saved has been returned, so a loop over them never hangs on a crashed
    daemon. ``database`` answers any other question about the runs.

    Requests may come from any thread; ``database``, ``poll()`` and
    ``wait()`` belong to the thread that created the daemon.

    Attributes
    ----------
    database_path : Path
        The path trnrund reported, not a guessed filename.
    session_id : int
        This daemon's session, recorded on every run it adds.
    start_revision, start_log_id : int
        The latest run revision and log ID when the daemon started. A reader
        that starts there sees only this daemon's changes.
    database : Database
        Read-only view of the runs, following from ``start_revision`` and
        ``start_log_id``.
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
        """Start the daemon, wait for ready, then open its database.

        Without database_path, the runs are kept in a temporary database,
        deleted by ``close()``. A given database is created if missing, but its
        directory must exist; an existing one keeps its runs and logs, and the
        daemon continues its run numbers in a new session. max_concurrent
        defaults to one less than the CPU count, at least 1. trnrund_path and
        trnrun_path default to the trnrund.exe and trnrun.exe bundled in
        ``trnrun/bin``. Relative paths use the current working directory.
        Requests that get no reply within request_timeout seconds raise
        TimeoutError. Startup failures raise RuntimeError with trnrund's
        message.
        """
        # Unwound by close(): the database, then the daemon, then a temporary directory.
        self._resources: ExitStack = ExitStack()
        try:
            if database_path is None:
                temporary = self._resources.enter_context(
                    TemporaryDirectory(prefix="trnrun-", ignore_cleanup_errors=True),
                )
                database_path = Path(temporary) / "runs.sqlite3"
            settings = DaemonSettings(
                trnrun_path=trnrun_path,
                max_concurrent=max_concurrent,
                database_path=database_path,
            )
            self._process: DaemonProcess = DaemonProcess(
                trnrund_path,
                settings.to_cli_args(),
                request_timeout=request_timeout,
            )
            _ = self._resources.callback(self._process.close)
            ready = self._process.request({"cmd": "ready"})
            self.database_path: Path = Path(_field(ready, "databasePath", str))
            self.session_id: int = _field(ready, "sessionId", int)
            self.start_revision: int = _field(ready, "revision", int)
            self.start_log_id: int = _field(ready, "logId", int)
            self.database: Database = Database(
                self.database_path,
                after_revision=self.start_revision,
                after_log_id=self.start_log_id,
            )
            _ = self._resources.callback(self.database.close)
        except BaseException:
            self._resources.close()
            raise

    # -----------------------------------------------------------------
    # Requests
    # -----------------------------------------------------------------
    def add(
        self,
        deck_file: str | Path,
        trnrun_args: Sequence[str] | SimulationSettings = (),
        *,
        label: str | None = None,
    ) -> int:
        """Submit a deck and return the run ID trnrund assigned; return after saving, not finishing.

        ``trnrun_args`` are raw TRNRun options or a ``SimulationSettings``.
        ``label`` is an optional tag saved with the run. A relative deck_file
        resolves from the current working directory now, not from the
        daemon's. Raises ValueError if trnrund rejects the run.
        """
        args = trnrun_args.to_cli_args() if isinstance(trnrun_args, SimulationSettings) else list(trnrun_args)
        request: dict[str, object] = {"cmd": "add", "deckFile": str(Path(deck_file).absolute()), "trnrunArgs": args}
        if label is not None:
            request["label"] = label
        return _field(self._process.request(request), "runId", int)

    def cancel(self, run_id: int) -> None:
        """Stop a queued or running run; return after recording it, not finishing.

        A queued run is FINISHED and CANCELLED on return; a running one becomes
        so once its TRNRun is killed. A finished run is left unchanged. Raises
        ValueError for an unknown run_id.
        """
        _ = self._process.request({"cmd": "cancel", "runId": run_id})

    def shutdown(self, *, cancel_running: bool = False, timeout: float | None = None) -> None:
        """Cancel queued runs, finish or kill running ones, and wait for trnrund to exit.

        Running runs are waited for, unless ``cancel_running`` kills them.
        If they are still running after ``timeout`` seconds, stdin is closed,
        which saves them as interrupted and kills them. ``database`` stays
        open until ``close()``. Raises RuntimeError if trnrund exits with an
        error.
        """
        _ = self._process.request({"cmd": "shutdown", "cancelRunning": cancel_running})
        if not self._process.wait(timeout):
            self._process.close()

    # -----------------------------------------------------------------
    # Following changes
    # -----------------------------------------------------------------
    def poll(self) -> Changes:
        """Return the runs and logs saved since the previous ``poll()`` or ``wait()``.

        Raises RuntimeError once trnrund has exited before ``shutdown()`` or
        ``close()`` and every change it saved has been returned.
        """
        # Checked before reading: once trnrund's stdout ended, everything it saved is readable.
        exit_error = self._process.exit_error()
        changes = self.database.poll()
        if not changes and exit_error is not None:
            raise exit_error
        return changes

    def wait(self, timeout: float | None = None) -> Changes:
        """Block until trnrund saves more changes, then return them as ``poll()`` does.

        Returns at once if changes are already waiting, and returns an empty
        ``Changes`` if ``timeout`` seconds pass first. After ``shutdown()``
        it no longer blocks.
        """
        _ = self._process.wait_for_change(self.database.revision, timeout)
        return self.poll()

    def wait_for_change(self, after_revision: int, timeout: float | None = None) -> bool:
        """Block until trnrund announces a revision after ``after_revision``, or exits.

        Returns False if ``timeout`` seconds pass first. Safe from any thread,
        for readers with their own ``Database``.
        """
        return self._process.wait_for_change(after_revision, timeout)

    def exit_error(self) -> RuntimeError | None:
        """Return how trnrund exited if it ended before ``shutdown()`` or ``close()``, else None."""
        return self._process.exit_error()

    # -----------------------------------------------------------------
    # Closing
    # -----------------------------------------------------------------
    def close(self) -> None:
        """Close ``database``, close stdin, interrupting unfinished runs, and wait for trnrund.

        trnrund is killed, with its runs, if it has not exited 10 seconds
        after stdin closes. A temporary database is then deleted. Safe to
        call more than once, including after the daemon crashed.
        """
        self._resources.close()

    def __enter__(self) -> Self:
        """Return this daemon for use in a with block."""
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Close resources and interrupt unfinished runs when leaving a with block."""
        self.close()
