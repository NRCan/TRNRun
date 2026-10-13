# ruff: noqa: S608 - tests build SQL only from their own column names

"""Writes a database the way trnrund does, so tests can play a daemon's runs."""

from __future__ import annotations

import json
import sqlite3
from collections.abc import Sequence
from pathlib import Path
from threading import RLock
from typing import Final

from trnrun.database import SCHEMA_VERSION

# Copied from trnrund's `database.nim`; change both together.
SCHEMA: Final[tuple[str, ...]] = (
    """CREATE TABLE runs (
      run_id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL,
      state TEXT NOT NULL,
      trnrun_status TEXT,
      trnrun_message TEXT,
      percent REAL,
      sim_time REAL,
      elapsed_ms REAL,
      eta_ms REAL,
      notices INTEGER NOT NULL,
      warnings INTEGER NOT NULL,
      fatals INTEGER NOT NULL,
      succeeded INTEGER,
      exit_code INTEGER,
      error TEXT,
      submitted_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      deck_file TEXT NOT NULL,
      trnrun_args TEXT NOT NULL,
      start_time REAL,
      stop_time REAL,
      time_step REAL,
      setting TEXT)""",
    "CREATE UNIQUE INDEX runs_revision ON runs (revision)",
    "CREATE INDEX runs_state ON runs (state, revision)",
    """CREATE TABLE logs (
      log_id INTEGER PRIMARY KEY,
      run_id TEXT NOT NULL,
      severity TEXT NOT NULL,
      sim_time REAL NOT NULL,
      unit_id INTEGER,
      type_id INTEGER,
      message_code INTEGER,
      message TEXT,
      information TEXT)""",
    "CREATE INDEX logs_run_id ON logs (run_id)",
)
NOW: Final[str] = "strftime('%Y-%m-%dT%H:%M:%fZ')"
COUNTERS: Final[dict[str, str]] = {"Notice": "notices", "Warning": "warnings", "Fatal": "fatals"}


class DaemonDatabase:
    """A trnrund database written as the daemon writes it: every change gives the run the next revision."""

    def __init__(self, path: Path, version: int = SCHEMA_VERSION) -> None:
        self.path: Path = path
        self.lock: RLock = RLock()
        self.connection: sqlite3.Connection = sqlite3.connect(path, isolation_level=None, check_same_thread=False)
        _ = self.connection.execute("PRAGMA journal_mode = WAL")
        for statement in SCHEMA:
            _ = self.connection.execute(statement)
        _ = self.connection.execute(f"PRAGMA user_version = {version}")

    def __contains__(self, run_id: str) -> bool:
        """Return whether `run_id` was ever saved."""
        with self.lock:
            return self.connection.execute("SELECT 1 FROM runs WHERE run_id = ?", (run_id,)).fetchone() is not None

    def submit(self, run_id: str, deck_file: str = r"C:\model.dck", trnrun_args: Sequence[str] = ()) -> None:
        """Save a new run as QUEUED."""
        with self.lock:
            _ = self.connection.execute(
                f"""INSERT INTO runs (run_id, revision, state, notices, warnings, fatals,
                    submitted_at, deck_file, trnrun_args)
                VALUES (?, (SELECT coalesce(max(revision), 0) + 1 FROM runs), 'QUEUED', 0, 0, 0, {NOW}, ?, ?)""",
                (run_id, deck_file, json.dumps(list(trnrun_args))),
            )

    def update(self, run_id: str, **columns: object) -> None:
        """Set columns of `run_id`, a `setting` dict as JSON, and give it the next revision."""
        if isinstance(setting := columns.get("setting"), dict):
            columns["setting"] = json.dumps(setting)
        assignments = "".join(f", {column} = ?" for column in columns)
        with self.lock:
            _ = self.connection.execute(
                f"UPDATE runs SET revision = (SELECT max(revision) + 1 FROM runs){assignments} WHERE run_id = ?",
                (*columns.values(), run_id),
            )

    def log(self, run_id: str, severity: str = "Notice", message: str | None = "message", **fields: object) -> None:
        """Append one log entry and count it, atomically, as the daemon does."""
        counter = COUNTERS[severity]
        entry: dict[str, object] = {
            "sim_time": 0.0,
            "unit_id": None,
            "type_id": None,
            "message_code": None,
            "information": None,
        }
        entry.update(fields)
        with self.lock:
            _ = self.connection.execute("BEGIN")
            _ = self.connection.execute(
                f"UPDATE runs SET revision = (SELECT max(revision) + 1 FROM runs), {counter} = {counter} + 1 WHERE run_id = ?",
                (run_id,),
            )
            _ = self.connection.execute(
                """INSERT INTO logs (run_id, severity, sim_time, unit_id, type_id, message_code, message, information)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    run_id,
                    severity,
                    entry["sim_time"],
                    entry["unit_id"],
                    entry["type_id"],
                    entry["message_code"],
                    message,
                    entry["information"],
                ),
            )
            _ = self.connection.execute("COMMIT")

    def finish(self, run_id: str, status: str = "DONE", exit_code: int | None = 0, error: str = "") -> None:
        """Finish a run with the daemon's success rule."""
        self.update(
            run_id,
            state="FINISHED",
            trnrun_status=status,
            trnrun_message="",
            exit_code=exit_code,
            error=error or None,
            succeeded=int(status == "DONE" and exit_code == 0 and not error),
        )

    def close(self) -> None:
        """Close the writer."""
        with self.lock:
            self.connection.close()
