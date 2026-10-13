"""Start trnrund, submit runs to it, and open its database for reading."""

from collections.abc import Sequence
from contextlib import ExitStack
from pathlib import Path
from types import TracebackType
from typing import Self

from .config import SimulationConfig
from .database import TrnRunDatabase
from .process import DEFAULT_EXECUTABLE, DaemonProcess


class Daemon:
    """Start trnrund and expose its database as a read-only SQLite connection.

    Use one thread per instance; requests are synchronous. Query runs and logs
    through `database`, a TrnRunDatabase, and call check() while polling it.
    """

    def __init__(
        self,
        database_path: str | Path = "trnrund.sqlite3",
        *,
        max_concurrent: int | None = None,
        trnrun_path: str | Path | None = None,
        overwrite: bool = False,
        executable: str | Path = DEFAULT_EXECUTABLE,
    ) -> None:
        """Start the daemon, wait for ready, then open its database.

        The database is created if missing, but its directory must exist; an
        existing one keeps its runs, logs, and taken run IDs. overwrite=True
        permanently deletes them instead. max_concurrent defaults to one less
        than the CPU count, at least 1. trnrun_path defaults to trnrun.exe
        beside the trnrund executable. Relative paths use the current working
        directory. Startup failures raise RuntimeError with trnrund's message.
        """
        self._resources: ExitStack = ExitStack()
        self._process: DaemonProcess = DaemonProcess(
            database_path=database_path,
            max_concurrent=max_concurrent,
            trnrun_path=trnrun_path,
            overwrite=overwrite,
            executable=executable,
        )
        _ = self._resources.callback(self._process.close)
        try:
            self.database_path: Path = self._ready()
            self.database: TrnRunDatabase = TrnRunDatabase(self.database_path)
            _ = self._resources.callback(self.database.close)
        except BaseException:
            self._resources.close()
            raise

    def _ready(self) -> Path:
        """Wait until trnrund accepts requests; return its database path."""
        database_path = self._process.request({"cmd": "ready"}).get("databasePath")
        if isinstance(database_path, str):
            return Path(database_path)
        raise RuntimeError("trnrund ready reply has no databasePath")

    def check(self) -> None:
        """Raise RuntimeError if trnrund exited before shutdown() or close().

        Call it while polling the database, which cannot tell a crashed daemon
        from runs that are still in progress.
        """
        self._process.check()

    def add(
        self,
        run_id: str,
        deck_file: str | Path,
        trnrun_args: Sequence[str] | SimulationConfig = (),
    ) -> None:
        """Submit raw arguments or a config; return after saving, not finishing.

        run_id must be new to the database, even across restarts. A relative
        deck_file resolves from the current working directory now, not from the
        daemon's, which was fixed when it started.
        """
        args = trnrun_args.to_cli_args() if isinstance(trnrun_args, SimulationConfig) else list(trnrun_args)
        _ = self._process.request(
            {"cmd": "add", "runId": run_id, "deckFile": str(Path(deck_file).absolute()), "trnrunArgs": args},
        )

    def cancel(self, run_id: str) -> None:
        """Stop a queued or running run; return after recording it, not finishing.

        A queued run is FINISHED and CANCELLED on return; a running one becomes
        so once its TRNSYS is killed. A finished run is left unchanged. Raises
        ValueError for an unknown run_id.
        """
        _ = self._process.request({"cmd": "cancel", "runId": run_id})

    def shutdown(self) -> None:
        """Cancel queued runs and wait for running ones; leave the database open.

        Raises RuntimeError if trnrund exits with an error.
        """
        _ = self._process.request({"cmd": "shutdown"})
        self._process.wait()

    def close(self) -> None:
        """Close the database and stdin, cancelling any unfinished simulations."""
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
        """Close resources and cancel unfinished runs when leaving a with block."""
        self.close()
