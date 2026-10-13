"""Read-only access to a trnrund database, independent of the daemon process."""

import sqlite3
from pathlib import Path

_SCHEMA_VERSION = 2


class TrnRunDatabase(sqlite3.Connection):
    """Read-only SQLite connection with TRNRun query helpers.

    Rows are sqlite3.Row, readable by column name. As with any SQLite
    connection, a with block does not close it; use closing() or close().
    """

    def __init__(self, path: str | Path) -> None:
        """Open an existing database read-only, in autocommit mode.

        Relative paths use the current working directory. Raises sqlite3.Error
        if it cannot be opened, or ValueError, after closing it, if its schema
        version is incompatible.
        """
        uri = Path(path).absolute().as_uri() + "?mode=ro"
        super().__init__(uri, uri=True, autocommit=True)
        self.row_factory = sqlite3.Row
        try:
            self._check_schema()
        except BaseException:
            self.close()
            raise

    def _check_schema(self) -> None:
        version = int(self.execute("PRAGMA user_version").fetchone()[0])
        if version != _SCHEMA_VERSION:
            raise ValueError(f"Unsupported TRNRun database schema {version}; expected {_SCHEMA_VERSION}")

    def get_run(self, run_id: str) -> sqlite3.Row | None:
        """Return a run's current snapshot, or None if its ID is unknown."""
        return self.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()

    def get_logs(self, run_id: str) -> list[sqlite3.Row]:
        """Return a run's logs ordered by log_id, or [] when there are none."""
        return self.execute("SELECT * FROM logs WHERE run_id = ? ORDER BY log_id", (run_id,)).fetchall()

    def get_new_logs(self, after_log_id: int, run_id: str | None = None) -> list[sqlite3.Row]:
        """Return logs with a larger log_id, of every run or only run_id, oldest first.

        Advance the caller's cursor to the last returned log_id; start from 0
        to include every existing log.
        """
        if run_id is None:
            return self.execute("SELECT * FROM logs WHERE log_id > ? ORDER BY log_id", (after_log_id,)).fetchall()
        return self.execute(
            "SELECT * FROM logs WHERE run_id = ? AND log_id > ? ORDER BY log_id",
            (run_id, after_log_id),
        ).fetchall()

    def get_latest_revision(self) -> int:
        """Return the maximum revision, or 0 if empty, for initial cursor setup."""
        return int(self.execute("SELECT coalesce(max(revision), 0) FROM runs").fetchone()[0])

    def get_running_runs(self) -> list[sqlite3.Row]:
        """Return currently running snapshots in revision order."""
        return self.execute("SELECT * FROM runs WHERE state = 'RUNNING' ORDER BY revision").fetchall()

    def count_runs_by_state(self) -> dict[str, int]:
        """Return the number of runs in each state, including states with none."""
        counts = dict(self.execute("SELECT state, count(*) FROM runs GROUP BY state").fetchall())
        return {state: counts.get(state, 0) for state in ("QUEUED", "ACCEPTED", "RUNNING", "FINISHED")}

    def get_changed_runs(self, after_revision: int) -> list[sqlite3.Row]:
        """Return newer ACCEPTED/RUNNING/FINISHED snapshots, ordered by revision.

        Advance the caller's cursor to the largest returned revision. This reads
        latest snapshots, not every intermediate event. Queued runs are excluded;
        a run that finishes between polls is still returned.
        """
        # IN rather than state != 'QUEUED', which cannot use the runs_state index.
        return self.execute(
            "SELECT * FROM runs WHERE revision > ? AND state IN ('ACCEPTED', 'RUNNING', 'FINISHED') "
            "ORDER BY revision",
            (after_revision,),
        ).fetchall()
