"""Shared test helpers: a trnrund-shaped database and fake TRNRun decks.

The daemon and manager tests run the bundled trnrund.exe with Python itself as
the TRNRun executable. trnrund starts TRNRun as ``<trnrun> <deck> <args...>``,
so Python runs the deck as a script, and ``write_deck`` writes decks that print
TRNRun's JSON events and exit with a chosen code.
"""

import sqlite3
import sys
from collections.abc import Sequence
from pathlib import Path

import pytest

from trnrun.daemon import DEFAULT_TRNRUND

# -----------------------------------------------------------------
# Executables
# -----------------------------------------------------------------
# The interpreter itself, not a venv redirector: trnrund cancels a run by killing TRNRun, and a
# redirector's child would outlive it and keep the output pipe open.
PYTHON = Path(sys._base_executable)
FAKE_TRNRUND = Path(__file__).parent / "fake_trnrund.py"

requires_trnrund = pytest.mark.skipif(
    not DEFAULT_TRNRUND.is_file(),
    reason="trnrun/bin/trnrund.exe is missing; run 'nimble deploy' in components/trnrund",
)

# -----------------------------------------------------------------
# Database
# -----------------------------------------------------------------
# Mirrors `Schema` in components/trnrund/src/database.nim; keep both at the same version.
SCHEMA_VERSION = 3
SCHEMA = (
    "CREATE TABLE sessions (session_id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL)",
    """CREATE TABLE runs (
      run_id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      label TEXT,
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
    """CREATE TABLE logs (
      log_id INTEGER PRIMARY KEY,
      run_id INTEGER NOT NULL,
      severity TEXT NOT NULL,
      sim_time REAL NOT NULL,
      unit_id INTEGER,
      type_id INTEGER,
      message_code INTEGER,
      message TEXT,
      information TEXT)""",
)

SUBMITTED_AT = "2026-10-09T14:03:12.345Z"

# A saved SETTING event, as trnrund stores it: TRNRun's camelCase keys.
SETTING = {
    "trnexePath": r"C:\TRNSYS18\Exe\TrnEXE64.exe",
    "guiVisibility": "hidden",
    "waitForGui": True,
    "waitForLst": True,
    "waitForTmp": False,
    "detectTimeoutMs": 300_000,
    "extraDelayMs": 0,
    "watchLog": True,
    "watchTmp": False,
    "watchTimeoutMs": 0,
    "stallTimeoutMs": 0,
    "pollMs": 100,
    "cleanOnSuccess": False,
    "killOnTimeout": False,
    "killOnStall": False,
    "severity": "Notice",
    "writeEvents": False,
}


def create_database(path: Path, *, version: int = SCHEMA_VERSION) -> sqlite3.Connection:
    """Create a database with trnrund's schema and return a writable connection to it."""
    connection = sqlite3.connect(path, autocommit=True)
    connection.row_factory = sqlite3.Row
    for statement in SCHEMA:
        _ = connection.execute(statement)
    _ = connection.execute(f"PRAGMA user_version = {version}")
    return connection


def _next_revision(connection: sqlite3.Connection) -> int:
    """Return the revision trnrund would give the next save."""
    return int(connection.execute("SELECT coalesce(max(revision), 0) + 1 FROM runs").fetchone()[0])


def insert_run(connection: sqlite3.Connection, **columns: object) -> int:
    """Save a run, queued in session 1 unless ``columns`` say otherwise, and return its run_id."""
    row: dict[str, object] = {
        "session_id": 1,
        "state": "QUEUED",
        "notices": 0,
        "warnings": 0,
        "fatals": 0,
        "submitted_at": SUBMITTED_AT,
        "deck_file": r"C:\decks\model.dck",
        "trnrun_args": "[]",
        "revision": _next_revision(connection),
        **columns,
    }
    names = ", ".join(row)
    marks = ", ".join("?" for _ in row)
    cursor = connection.execute(f"INSERT INTO runs ({names}) VALUES ({marks})", tuple(row.values()))  # noqa: S608 - test columns
    return int(cursor.lastrowid or 0)


def update_run(connection: sqlite3.Connection, run_id: int, **columns: object) -> None:
    """Change a run's columns and give it the next revision, as trnrund does."""
    row = {**columns, "revision": _next_revision(connection)}
    assignments = ", ".join(f"{name} = ?" for name in row)
    _ = connection.execute(f"UPDATE runs SET {assignments} WHERE run_id = ?", (*row.values(), run_id))  # noqa: S608 - test columns


def insert_log(connection: sqlite3.Connection, run_id: int, **columns: object) -> int:
    """Save a Notice log entry for ``run_id`` unless ``columns`` say otherwise, and return its log_id."""
    row: dict[str, object] = {"run_id": run_id, "severity": "Notice", "sim_time": 0.0, **columns}
    names = ", ".join(row)
    marks = ", ".join("?" for _ in row)
    cursor = connection.execute(f"INSERT INTO logs ({names}) VALUES ({marks})", tuple(row.values()))  # noqa: S608 - test columns
    return int(cursor.lastrowid or 0)


def fetch_row(connection: sqlite3.Connection, table: str, key: str, value: int) -> sqlite3.Row:
    """Return one row of ``table`` by its key column."""
    return connection.execute(f"SELECT * FROM {table} WHERE {key} = ?", (value,)).fetchone()  # noqa: S608 - test tables


# -----------------------------------------------------------------
# Fake TRNRun decks
# -----------------------------------------------------------------
# What a successful run prints: one log entry of each severity, then a DONE status.
DONE_EVENTS: list[dict[str, object]] = [
    {"kind": "STATUS", "status": "RUNNING", "message": ""},
    {"kind": "CONFIG", "start": 0, "stop": 10, "step": 1},
    {"kind": "LOG", "severity": "Notice", "time": 0, "message": "first"},
    {
        "kind": "LOG",
        "severity": "Warning",
        "time": 5,
        "unitId": 7,
        "typeId": 56,
        "messageCode": 123,
        "message": "second",
        "information": "details",
    },
    {"kind": "LOG", "severity": "Fatal", "time": 10, "message": "third"},
    {"kind": "PROGRESS", "time": 10, "percent": 1, "elapsedMs": 5, "etaMs": 0},
    {"kind": "STATUS", "status": "DONE", "message": ""},
]
FAILED_EVENTS: list[dict[str, object]] = [{"kind": "STATUS", "status": "ERROR", "message": "Fake failure"}]
GATE_TIMEOUT = 30.0  # Seconds a gated deck waits for its release before going on anyway.

_DECK = """\
import json, sys, time
from pathlib import Path

release = Path(sys.argv[0]).with_suffix(".release")
deadline = time.monotonic() + {timeout}
while {gated} and not release.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
for event in {events!r}:
    print(json.dumps(event), flush=True)
sys.exit({exit_code})
"""


def write_deck(
    path: Path,
    events: Sequence[dict[str, object]] = DONE_EVENTS,
    *,
    exit_code: int = 0,
    gated: bool = False,
) -> Path:
    """Write a deck that prints ``events`` as TRNRun would, then exits with ``exit_code``.

    A gated deck first waits for ``release(path)``, so a test can hold it
    running.
    """
    _ = path.write_text(
        _DECK.format(timeout=GATE_TIMEOUT, gated=gated, events=list(events), exit_code=exit_code),
        encoding="utf-8",
    )
    return path


def release(deck: Path) -> None:
    """Let a gated deck go on."""
    deck.with_suffix(".release").touch()
