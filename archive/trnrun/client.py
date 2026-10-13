"""Typed requests to one TRNRun daemon, and the database it keeps its runs in."""

from __future__ import annotations

import os
import shutil
import tempfile
from collections.abc import Sequence
from pathlib import Path
from types import TracebackType
from typing import Final, Self

from trnrun.config import BUNDLED_TRNRUN_PATH, BUNDLED_TRNRUND_PATH
from trnrun.database import RunDatabase
from trnrun.process import DaemonProcess

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)


class DaemonClient:
    """Send trnrund protocol requests, and read the runs from its database.

    Each request method sends one request and waits for its reply. The daemon
    saves every change to a run in its SQLite database; ``database`` reads it,
    so following runs never waits on the daemon. The client keeps no state:
    the caller picks each ``run_id`` and decides when to poll. Requests from
    several threads are serialized.

    Parameters
    ----------
    max_concurrent : int, optional
        Simulations the daemon runs at once.
    database : str or Path, optional
        SQLite database to keep the runs in, created if missing; its directory
        must exist. By default, a new temporary database, deleted by ``kill()``.
        A run ID can never be reused in the same database, and only one daemon
        at a time can use it.
    overwrite : bool, default False
        Have the daemon delete and recreate the database and its journals.
        Close existing readers first; another daemon using it is refused.
        Deleted data is not restored if startup fails. This client's reader
        opens only after the new database is ready.
    trnrun_path : str or Path, optional
        TRNRun executable the daemon runs; the bundled one by default.
    trnrund_path : str or Path, optional
        Daemon executable; the bundled one by default.

    Raises
    ------
    TypeError
        If ``overwrite`` is not a boolean.
    FileNotFoundError
        If either executable is missing.
    RuntimeError
        If the daemon rejects its configuration, cannot use the database, for
        example because another daemon uses it, or exits during startup.

    Notes
    -----
    A request the daemon rejects, or a malformed reply, raises ``ValueError``;
    a daemon that exited raises ``RuntimeError``. Always release the client
    with ``kill()``, or by leaving a ``with`` block, even after ``shutdown()``.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        *,
        database: str | Path | None = None,
        overwrite: bool = False,
        trnrun_path: str | Path = BUNDLED_TRNRUN_PATH,
        trnrund_path: str | Path = BUNDLED_TRNRUND_PATH,
    ) -> None:
        self._temporary: Path | None = None
        if database is None:
            self._temporary = Path(tempfile.mkdtemp(prefix="trnrun-"))
            database = self._temporary / "runs.sqlite3"
        try:
            self._process: DaemonProcess = DaemonProcess(
                trnrund_path,
                trnrun_path,
                max_concurrent,
                database,
                overwrite=overwrite,
            )
            try:
                # Runs saved by earlier daemons are not this client's to follow.
                self.database: RunDatabase = RunDatabase(self._process.database_path, skip_existing=True)
            except BaseException:
                self._process.kill()
                raise
        except BaseException:
            self._remove_temporary()
            raise

    @property
    def database_path(self) -> Path:
        """Return the absolute path of the daemon's database."""
        return self._process.database_path

    def add(self, run_id: str, deck_file: str | Path, trnrun_args: Sequence[str] = ()) -> None:
        """Queue a simulation, which starts once a worker is free.

        Returns ``None`` once the daemon validates and saves the submission,
        not once it starts or succeeds. Read lifecycle state from ``database``.
        Raises ``ValueError`` if ``run_id`` is empty or was ever used in the
        database, the deck is missing or not a ``.dck`` or ``.trd`` file, or
        ``trnrun.exe`` would reject ``trnrun_args``.
        """
        _ = self._process.request(
            {"cmd": "add", "runId": run_id, "deckFile": str(deck_file), "trnrunArgs": list(trnrun_args)},
        )

    def exit_error(self) -> RuntimeError | None:
        """Return the error describing the daemon's exit, with its diagnostics, or None while it runs.

        The database keeps what the daemon saved, but a daemon that exited
        unexpectedly never finishes its runs.
        """
        return self._process.exit_error()

    def shutdown(self, timeout: float | None = None) -> None:
        """Have the daemon cancel queued runs, finish running ones, and exit.

        Waits for the exit, up to ``timeout`` seconds if given. ``database``
        stays readable, so a last ``pull()`` returns the final states, until
        ``kill()``. Requests sent afterwards raise ``RuntimeError``. On
        ``subprocess.TimeoutExpired`` the daemon keeps running; ``kill()``
        still stops it.
        """
        _ = self._process.request({"cmd": "shutdown"})
        self._process.wait(timeout)

    def kill(self) -> None:
        """Kill the daemon and the simulations it runs, then close ``database``, deleting a temporary one.

        Calling it again is harmless.
        """
        try:
            self._process.kill()
        finally:
            self.database.close()
            self._remove_temporary()

    def __enter__(self) -> Self:
        """Return the client."""
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Kill the daemon when leaving the context."""
        self.kill()

    def _remove_temporary(self) -> None:
        """Delete the temporary database directory, if the client made one; best effort."""
        if self._temporary is not None:
            shutil.rmtree(self._temporary, ignore_errors=True)
