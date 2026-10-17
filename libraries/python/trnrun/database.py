"""Open a trnrund database read-only, with or without a daemon, and read what changed."""

# pyright: reportAny=false

import sqlite3
from pathlib import Path

from .errors import SchemaVersionError
from .runs import Changes, parse_log, parse_run

SCHEMA_VERSION = 3


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
