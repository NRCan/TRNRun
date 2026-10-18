"""Open a trnrund database read-only, with or without a daemon, and read its rows as typed records."""

# pyright: reportAny=false

import json
import sqlite3
from datetime import datetime
from pathlib import Path

from trnrun.core.errors import SchemaVersionError
from trnrun.core.records import (
    Changes,
    ConfigEvent,
    LogEvent,
    LogSeverity,
    ProgressEvent,
    SimulationInfo,
    SimulationState,
    SimulationStatus,
)

SCHEMA_VERSION = 3


# -----------------------------------------------------------------
# Row Parsers
# -----------------------------------------------------------------
def _parse_timestamp(value: str | None) -> datetime | None:
    """Parse a saved UTC timestamp, such as ``2026-10-09T14:03:12.345Z``."""
    return None if value is None else datetime.fromisoformat(value)


def parse_run(row: sqlite3.Row) -> SimulationInfo:
    """Parse a ``SELECT *`` row of ``runs``; an event TRNRun has not reported yet becomes None."""
    status = row["trnrun_status"]
    percent = row["percent"]
    stop = row["stop_time"]
    setting = row["setting"]
    succeeded = row["succeeded"]
    return SimulationInfo(
        run_id=row["run_id"],
        state=SimulationState(row["state"]),
        deck_file=Path(row["deck_file"]),
        session_id=row["session_id"],
        label=row["label"],
        revision=row["revision"],
        trnrun_args=json.loads(row["trnrun_args"]),
        status=None if status is None else SimulationStatus(status),
        status_message=row["trnrun_message"],
        progress=None if percent is None else ProgressEvent(row["sim_time"], percent, row["elapsed_ms"], row["eta_ms"]),
        config=None if stop is None else ConfigEvent(row["start_time"], stop, row["time_step"]),
        setting=None if setting is None else json.loads(setting),
        notices=row["notices"],
        warnings=row["warnings"],
        fatals=row["fatals"],
        succeeded=None if succeeded is None else bool(succeeded),
        exit_code=row["exit_code"],
        error=row["error"],
        submitted_at=_parse_timestamp(row["submitted_at"]),
        started_at=_parse_timestamp(row["started_at"]),
        finished_at=_parse_timestamp(row["finished_at"]),
    )


def parse_log(row: sqlite3.Row) -> LogEvent:
    """Parse a ``SELECT *`` row of ``logs``."""
    return LogEvent(
        log_id=row["log_id"],
        run_id=row["run_id"],
        severity=LogSeverity(row["severity"]),
        time=row["sim_time"],
        unit_id=row["unit_id"],
        type_id=row["type_id"],
        message_code=row["message_code"],
        message=row["message"],
        information=row["information"],
    )


# -----------------------------------------------------------------
# Reading
# -----------------------------------------------------------------
def connect(path: str | Path, *, check_same_thread: bool = True) -> sqlite3.Connection:
    """Open an existing trnrund database read-only, in autocommit mode, with ``sqlite3.Row`` rows.

    Open it while trnrund runs: right after trnrund is killed, a new
    connection can fail with ``disk I/O error``, while an open one keeps reading.

    Raises
    ------
    sqlite3.Error
        If the database cannot be opened.
    SchemaVersionError
        If its schema version is not ``SCHEMA_VERSION``.
    """
    connection = sqlite3.connect(
        Path(path).absolute().as_uri() + "?mode=ro",
        uri=True,
        autocommit=True,
        check_same_thread=check_same_thread,
    )
    connection.row_factory = sqlite3.Row
    try:
        _check_schema(connection)
    except BaseException:
        connection.close()
        raise
    return connection


def _check_schema(connection: sqlite3.Connection) -> None:
    """Raise SchemaVersionError unless the database has the schema this package reads."""
    version = int(connection.execute("PRAGMA user_version").fetchone()[0])
    if version != SCHEMA_VERSION:
        raise SchemaVersionError(f"Unsupported TRNRun database schema {version}; expected {SCHEMA_VERSION}")


def read_changes(connection: sqlite3.Connection, after_revision: int = 0, after_log_id: int = 0) -> Changes:
    """Return the runs and logs saved after these positions, read in one transaction.

    Pass the returned ``revision`` and ``log_id`` to the next call. Call it
    outside any transaction of your own.
    """
    _ = connection.execute("BEGIN")
    try:
        run_rows = connection.execute(
            "SELECT * FROM runs WHERE revision > ? ORDER BY revision",
            (after_revision,),
        ).fetchall()
        log_rows = connection.execute(
            "SELECT * FROM logs WHERE log_id > ? ORDER BY log_id",
            (after_log_id,),
        ).fetchall()
    finally:
        _ = connection.execute("COMMIT")
    runs = [parse_run(row) for row in run_rows]
    logs = [parse_log(row) for row in log_rows]
    return Changes(
        runs,
        logs,
        revision=runs[-1].revision if runs else after_revision,
        log_id=logs[-1].log_id if logs else after_log_id,
    )
