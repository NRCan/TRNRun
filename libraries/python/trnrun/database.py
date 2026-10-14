"""Read-only access to a trnrund database, independent of the daemon process."""

# pyright: reportAny=false

import sqlite3
from collections.abc import Generator, Sequence
from contextlib import contextmanager
from pathlib import Path
from types import TracebackType
from typing import Self

from .records import Changes, LogEvent, SimulationInfo, SimulationState, parse_log, parse_run

SCHEMA_VERSION = 3


class Database:
    """Read-only view of a trnrund database, with typed results.

    ``poll()`` returns what changed since the previous call and remembers
    where it stopped, so following runs needs no cursor bookkeeping. Use it as
    a context manager, or call ``close()``. Like any SQLite connection, it
    belongs to the thread that opened it.

    Attributes
    ----------
    path : Path
        Absolute path of the database.
    revision : int
        Largest run revision ``poll()`` has returned or skipped.
    log_id : int
        Largest log ID ``poll()`` has returned or skipped.
    """

    def __init__(self, path: str | Path, *, after_revision: int = 0, after_log_id: int = 0) -> None:
        """Open an existing database read-only.

        ``poll()`` starts after ``after_revision`` and ``after_log_id``; the
        defaults read the whole history, and ``seek_end()`` skips it.
        Relative paths use the current working directory. Raises
        ``sqlite3.Error`` if it cannot be opened, or ``ValueError``, after
        closing it, if its schema version is incompatible.
        """
        self.path: Path = Path(path).absolute()
        self.revision: int = after_revision
        self.log_id: int = after_log_id
        self._connection: sqlite3.Connection = sqlite3.connect(
            self.path.as_uri() + "?mode=ro",
            uri=True,
            autocommit=True,
        )
        self._connection.row_factory = sqlite3.Row
        try:
            self._check_schema()
        except BaseException:
            self._connection.close()
            raise

    def _check_schema(self) -> None:
        """Raise ValueError unless the database has the schema this package reads."""
        version = int(self._connection.execute("PRAGMA user_version").fetchone()[0])
        if version != SCHEMA_VERSION:
            raise ValueError(f"Unsupported TRNRun database schema {version}; expected {SCHEMA_VERSION}")

    # -----------------------------------------------------------------
    # Following changes
    # -----------------------------------------------------------------
    @contextmanager
    def _snapshot(self) -> Generator[None]:
        """Read every query inside the block from one consistent database state."""
        _ = self._connection.execute("BEGIN")
        try:
            yield
        finally:
            _ = self._connection.execute("COMMIT")

    def poll(self) -> Changes:
        """Return the runs and logs saved since the previous poll, and advance past them.

        Runs and logs are read from one snapshot, so the logs saved with each
        returned run are included.
        """
        with self._snapshot():
            run_rows = self._connection.execute(
                "SELECT * FROM runs WHERE revision > ? ORDER BY revision",
                (self.revision,),
            ).fetchall()
            log_rows = self._connection.execute(
                "SELECT * FROM logs WHERE log_id > ? ORDER BY log_id",
                (self.log_id,),
            ).fetchall()
        changes = Changes([parse_run(row) for row in run_rows], [parse_log(row) for row in log_rows])
        if changes.runs:
            self.revision = changes.runs[-1].revision
        if changes.logs:
            self.log_id = changes.logs[-1].log_id
        return changes

    def seek_end(self) -> None:
        """Skip everything saved so far; the next ``poll()`` returns only later changes."""
        with self._snapshot():
            self.revision = int(self._connection.execute("SELECT coalesce(max(revision), 0) FROM runs").fetchone()[0])
            self.log_id = int(self._connection.execute("SELECT coalesce(max(log_id), 0) FROM logs").fetchone()[0])

    # -----------------------------------------------------------------
    # Queries
    # -----------------------------------------------------------------
    def get_run(self, run_id: int) -> SimulationInfo | None:
        """Return a run's current snapshot, or None if its ID is unknown."""
        row = self._connection.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()
        return None if row is None else parse_run(row)

    def get_logs(self, run_id: int) -> list[LogEvent]:
        """Return a run's logs, oldest first; [] when there are none."""
        rows = self._connection.execute("SELECT * FROM logs WHERE run_id = ? ORDER BY log_id", (run_id,))
        return [parse_log(row) for row in rows]

    def get_runs(
        self,
        *,
        session_id: int | None = None,
        state: SimulationState | None = None,
    ) -> list[SimulationInfo]:
        """Return the runs of one session, in one state, or both, in the order they last changed.

        With neither, returns every run.
        """
        conditions: list[str] = []
        parameters: list[object] = []
        if session_id is not None:
            conditions.append("session_id = ?")
            parameters.append(session_id)
        if state is not None:
            conditions.append("state = ?")
            parameters.append(str(state))
        where = f" WHERE {' AND '.join(conditions)}" if conditions else ""
        rows = self._connection.execute(f"SELECT * FROM runs{where} ORDER BY revision", parameters)  # noqa: S608 - fixed conditions
        return [parse_run(row) for row in rows]

    def count_runs_by_state(self, *, session_id: int | None = None) -> dict[SimulationState, int]:
        """Return the number of runs in each state, every state included, of one session or all."""
        if session_id is None:
            rows = self._connection.execute("SELECT state, count(*) FROM runs GROUP BY state")
        else:
            rows = self._connection.execute(
                "SELECT state, count(*) FROM runs WHERE session_id = ? GROUP BY state",
                (session_id,),
            )
        counts = {SimulationState(state): count for state, count in rows}
        return {state: counts.get(state, 0) for state in SimulationState}

    def execute(self, sql: str, parameters: Sequence[object] = ()) -> sqlite3.Cursor:
        """Run a custom read-only query; rows are ``sqlite3.Row``, readable by column name.

        Bind values with ``?`` parameters rather than formatting them into
        ``sql``. Finish the cursor promptly to keep reads short.
        """
        return self._connection.execute(sql, parameters)

    # -----------------------------------------------------------------
    # Closing
    # -----------------------------------------------------------------
    def close(self) -> None:
        """Close the connection. Safe to call more than once."""
        self._connection.close()

    def __enter__(self) -> Self:
        """Return this database for use in a with block."""
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Close the connection when leaving a with block."""
        self.close()
