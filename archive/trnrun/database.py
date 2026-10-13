"""Read-only access to the SQLite database a TRNRun daemon keeps up to date.

The daemon saves every change to a run as it happens and gives the run's row
the next ``revision``, so a reader remembers the largest it has seen and asks
only for what came after. See the trnrund README for the full schema.
"""

# pyright: reportAny=false

from __future__ import annotations

import json
import sqlite3
from _thread import LockType
from collections.abc import Generator
from contextlib import contextmanager
from pathlib import Path
from threading import Lock
from types import TracebackType
from typing import Final, Self

from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SimulationReply,
    SimulationState,
    SimulationStatus,
    StatusEvent,
    parse_setting,
)

SCHEMA_VERSION: Final[int] = 2


class RunDatabase:
    """Read the simulations of a trnrund database.

    ``get()`` and ``logs()`` read one run as it is now. ``pull()`` returns the
    runs saved since the previous pull, so a poller costs what changed, not
    the number of runs. The database is opened read-only, so it can be read
    while its daemon runs, or after it exits. Reads from several threads are
    serialized. Close standalone readers explicitly with ``close()`` or a
    ``with`` block; ``DaemonClient`` closes its own reader.

    Parameters
    ----------
    path : str or Path
        The database, such as ``DaemonClient.database_path``.
    skip_existing : bool, default False
        Start after the runs already saved, so ``pull()`` returns only later
        changes; otherwise the first ``pull()`` returns every run.

    Raises
    ------
    sqlite3.Error
        If the database cannot be opened.
    ValueError
        If its schema is not the one this package reads.
    """

    def __init__(
        self,
        path: str | Path,
        *,
        skip_existing: bool = False,
    ) -> None:
        self.path: Path = Path(path).absolute()
        self._lock: LockType = Lock()
        # Each SELECT reads its own snapshot without leaving a transaction open.
        connection = sqlite3.connect(
            self.path.as_uri() + "?mode=ro",
            uri=True,
            isolation_level=None,
            check_same_thread=False,
        )
        connection.row_factory = sqlite3.Row
        self._connection: sqlite3.Connection = connection
        self._closed: bool = False
        self._revision: int = 0
        try:
            with self._read() as connection:
                self._check_version(connection)
                if skip_existing:
                    self._revision = connection.execute("SELECT coalesce(max(revision), 0) FROM runs").fetchone()[0]
        except BaseException:
            self.close()
            raise

    def pull(self) -> dict[str, SimulationReply]:
        """Return the simulations changed since the last pull, by run ID, in the order they last changed.

        Each change is pulled once. A finished run never changes after.
        """
        with self._read() as connection:
            rows: list[sqlite3.Row] = connection.execute(
                "SELECT * FROM runs WHERE revision > ? ORDER BY revision",
                (self._revision,),
            ).fetchall()
            pulled = {row["run_id"]: _simulation(row) for row in rows}
            # Advanced once parsed, so a row that fails to parse is not skipped silently.
            if rows:
                self._revision = rows[-1]["revision"]
        return pulled

    def get(self, run_id: str) -> SimulationReply | None:
        """Return the current state of ``run_id``, or None if it was never saved."""
        with self._read() as connection:
            row: sqlite3.Row | None = connection.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()
            return None if row is None else _simulation(row)

    def logs(self, run_id: str) -> list[LogEvent]:
        """Return every log entry of ``run_id`` saved so far, oldest first; all of them once it is finished."""
        with self._read() as connection:
            rows: list[sqlite3.Row] = connection.execute(
                "SELECT * FROM logs WHERE run_id = ? ORDER BY log_id",
                (run_id,),
            ).fetchall()
        return [_log(row) for row in rows]

    def max_numeric_run_id(self) -> int:
        """Return the largest run ID made only of digits, or 0 if there is none."""
        with self._read() as connection:
            return connection.execute(
                """SELECT coalesce(max(CAST(run_id AS INTEGER)), 0) FROM runs
                WHERE run_id <> '' AND run_id NOT GLOB '*[^0-9]*'""",
            ).fetchone()[0]

    def close(self) -> None:
        """Close the database once no read holds it; calling it again is harmless."""
        with self._lock:
            if not self._closed:
                self._connection.close()
                self._closed = True

    def __enter__(self) -> Self:
        """Return the database."""
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Close the database when leaving the context."""
        self.close()

    def _check_version(self, connection: sqlite3.Connection) -> None:
        """Refuse a database whose schema this package does not read."""
        version: int = connection.execute("PRAGMA user_version").fetchone()[0]
        if version != SCHEMA_VERSION:
            raise ValueError(
                f"TRNRun database {self.path} has schema version {version}; this trnrun reads {SCHEMA_VERSION}",
            )

    @contextmanager
    def _read(self) -> Generator[sqlite3.Connection]:
        """Serialize reads and prevent the connection from closing during one."""
        with self._lock:
            if self._closed:
                raise RuntimeError(f"TRNRun database {self.path} is closed")
            yield self._connection


def _log(row: sqlite3.Row) -> LogEvent:
    """Parse one row of the ``logs`` table."""
    return LogEvent(
        severity=row["severity"],
        time=row["sim_time"],
        unit_id=row["unit_id"],
        type_id=row["type_id"],
        message_code=row["message_code"],
        message=row["message"],
        information=row["information"],
    )


def _simulation(row: sqlite3.Row) -> SimulationReply:
    """Parse one row of the ``runs`` table.

    The daemon saves each TRNRun event's columns together, so one of them being
    ``NULL`` means TRNRun has not reported that event yet.
    """
    setting: str | None = row["setting"]
    return SimulationReply(
        state=SimulationState(row["state"]),
        exit_code=row["exit_code"],
        error=row["error"] or "",
        setting=None if setting is None else parse_setting(json.loads(setting)),
        status=None
        if row["trnrun_status"] is None
        else StatusEvent(SimulationStatus(row["trnrun_status"]), row["trnrun_message"] or ""),
        config=None
        if row["start_time"] is None
        else ConfigEvent(row["start_time"], row["stop_time"], row["time_step"]),
        progress=None
        if row["percent"] is None
        else ProgressEvent(row["sim_time"], row["percent"], row["elapsed_ms"], row["eta_ms"]),
        notices=row["notices"],
        warnings=row["warnings"],
        fatals=row["fatals"],
        succeeded=bool(row["succeeded"]),
    )
