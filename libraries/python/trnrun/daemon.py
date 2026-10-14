"""Start trnrund, submit runs to it, and follow them through its database."""

from collections.abc import Sequence
from pathlib import Path
from types import TracebackType
from typing import Self

from .config import SimulationConfig
from .database import Database
from .process import DEFAULT_EXECUTABLE, DEFAULT_REQUEST_TIMEOUT, DaemonProcess
from .records import Changes


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
        database_path: str | Path = "trnrund.sqlite3",
        *,
        max_concurrent: int | None = None,
        trnrun_path: str | Path | None = None,
        executable: str | Path = DEFAULT_EXECUTABLE,
        request_timeout: float = DEFAULT_REQUEST_TIMEOUT,
    ) -> None:
        """Start the daemon, wait for ready, subscribe to its changes, then open its database.

        The database is created if missing, but its directory must exist; an
        existing one keeps its runs and logs, and the daemon continues its run
        numbers in a new session. max_concurrent defaults to one less than the
        CPU count, at least 1. trnrun_path defaults to trnrun.exe beside the
        trnrund executable. Relative paths use the current working directory.
        Requests that get no reply within request_timeout seconds raise
        TimeoutError. Startup failures raise RuntimeError with trnrund's
        message.
        """
        self._process: DaemonProcess = DaemonProcess(
            database_path=database_path,
            max_concurrent=max_concurrent,
            trnrun_path=trnrun_path,
            executable=executable,
            request_timeout=request_timeout,
        )
        try:
            ready = self._process.request({"cmd": "ready"})
            self.database_path: Path = Path(_field(ready, "databasePath", str))
            self.session_id: int = _field(ready, "sessionId", int)
            self.start_revision: int = _field(ready, "revision", int)
            self.start_log_id: int = _field(ready, "logId", int)
            _ = self._process.request({"cmd": "subscribe"})
            self.database: Database = Database(
                self.database_path,
                after_revision=self.start_revision,
                after_log_id=self.start_log_id,
            )
        except BaseException:
            self._process.close()
            raise

    # -----------------------------------------------------------------
    # Requests
    # -----------------------------------------------------------------
    def add(
        self,
        deck_file: str | Path,
        trnrun_args: Sequence[str] | SimulationConfig = (),
        *,
        label: str | None = None,
    ) -> int:
        """Submit a deck and return the run ID trnrund assigned; return after saving, not finishing.

        ``trnrun_args`` are raw TRNRun options or a ``SimulationConfig``.
        ``label`` is an optional tag saved with the run. A relative deck_file
        resolves from the current working directory now, not from the
        daemon's. Raises ValueError if trnrund rejects the run.
        """
        args = trnrun_args.to_cli_args() if isinstance(trnrun_args, SimulationConfig) else list(trnrun_args)
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

    def check(self) -> None:
        """Raise RuntimeError if trnrund exited before ``shutdown()`` or ``close()``."""
        error = self._process.exit_error()
        if error is not None:
            raise error

    # -----------------------------------------------------------------
    # Closing
    # -----------------------------------------------------------------
    def close(self) -> None:
        """Close stdin, interrupting unfinished runs, wait for trnrund, then close ``database``.

        Safe to call more than once, including after the daemon crashed.
        """
        try:
            self._process.close()
        finally:
            self.database.close()

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
