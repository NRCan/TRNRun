"""Tests for ``trnrun.core.database``: opening a trnrund database and reading its changes."""

import sqlite3
from collections.abc import Iterator
from pathlib import Path

import pytest

from tests.helpers import create_database, insert_log, insert_run, update_run
from trnrun.core.database import connect, read_changes
from trnrun.core.errors import SchemaVersionError
from trnrun.core.records import SimulationState


@pytest.fixture
def path(tmp_path: Path) -> Path:
    """Return the path of a database file with trnrund's schema."""
    path = tmp_path / "runs.sqlite3"
    create_database(path).close()
    return path


@pytest.fixture
def writer(path: Path) -> Iterator[sqlite3.Connection]:
    """Return a writable connection standing in for trnrund."""
    connection = sqlite3.connect(path, autocommit=True)
    yield connection
    connection.close()


@pytest.fixture
def reader(path: Path) -> Iterator[sqlite3.Connection]:
    """Return the database opened read-only."""
    connection = connect(path)
    yield connection
    connection.close()


# -----------------------------------------------------------------
# connect
# -----------------------------------------------------------------
def test_connect_resolves_a_relative_path(
    path: Path,
    writer: sqlite3.Connection,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Resolve a relative path from the current working directory."""
    monkeypatch.chdir(path.parent)
    _ = insert_run(writer)

    connection = connect(path.name)

    assert connection.execute("SELECT count(*) FROM runs").fetchone()[0] == 1
    connection.close()


def test_connect_to_a_missing_database_fails(tmp_path: Path) -> None:
    """Never create a database: trnrund owns it."""
    with pytest.raises(sqlite3.OperationalError):
        _ = connect(tmp_path / "missing.sqlite3")
    assert not (tmp_path / "missing.sqlite3").exists()


def test_connect_rejects_another_schema_version_and_closes(tmp_path: Path) -> None:
    """Refuse a database this package cannot read, without leaving it open."""
    path = tmp_path / "old.sqlite3"
    create_database(path, version=2).close()

    with pytest.raises(SchemaVersionError, match="Unsupported TRNRun database schema 2; expected 3") as raised:
        _ = connect(path)
    assert isinstance(raised.value, ValueError)
    path.unlink()  # Fails on Windows while a connection still holds the file.


def test_connection_is_read_only(reader: sqlite3.Connection) -> None:
    """Never let a reader write to trnrund's database."""
    with pytest.raises(sqlite3.OperationalError, match="readonly"):
        _ = reader.execute("INSERT INTO sessions (started_at) VALUES ('now')")


def test_rows_are_readable_by_column_name(writer: sqlite3.Connection, reader: sqlite3.Connection) -> None:
    """Return ``sqlite3.Row``s, so plain SQL reads columns by name."""
    run_id = insert_run(writer, label="custom")

    row = reader.execute("SELECT run_id, label FROM runs WHERE label = ?", ("custom",)).fetchone()

    assert (row["run_id"], row["label"]) == (run_id, "custom")


# -----------------------------------------------------------------
# read_changes
# -----------------------------------------------------------------
def test_read_changes_returns_everything_then_only_what_is_new(
    writer: sqlite3.Connection,
    reader: sqlite3.Connection,
) -> None:
    """Return the positions to read after, so nothing is returned twice."""
    first = insert_run(writer)
    second = insert_run(writer)
    log = insert_log(writer, first, message="hello")

    changes = read_changes(reader)

    assert [info.run_id for info in changes.runs] == [first, second]
    assert [entry.log_id for entry in changes.logs] == [log]
    assert (changes.revision, changes.log_id) == (2, log)
    assert not read_changes(reader, changes.revision, changes.log_id)

    update_run(writer, first, state="RUNNING")
    later_log = insert_log(writer, first, severity="Warning")

    later = read_changes(reader, changes.revision, changes.log_id)

    assert [(info.run_id, info.state) for info in later.runs] == [(first, SimulationState.RUNNING)]
    assert [entry.log_id for entry in later.logs] == [later_log]


def test_read_changes_returns_the_latest_snapshot_in_change_order(
    writer: sqlite3.Connection,
    reader: sqlite3.Connection,
) -> None:
    """Return each run once, at its latest revision, ordered by when it last changed."""
    first = insert_run(writer)
    second = insert_run(writer)
    update_run(writer, first, state="RUNNING")
    update_run(writer, first, state="FINISHED", trnrun_status="DONE", succeeded=1, exit_code=0)

    changes = read_changes(reader)

    assert [info.run_id for info in changes.runs] == [second, first]
    assert changes.runs[-1].state is SimulationState.FINISHED
    assert changes.runs[-1].revision == changes.revision == 4


def test_read_changes_starts_after_the_given_positions(writer: sqlite3.Connection, reader: sqlite3.Connection) -> None:
    """Skip the history up to ``after_revision`` and ``after_log_id``."""
    old = insert_run(writer)
    old_log = insert_log(writer, old)
    new = insert_run(writer)
    new_log = insert_log(writer, new)

    changes = read_changes(reader, 1, old_log)

    assert [info.run_id for info in changes.runs] == [new]
    assert [entry.log_id for entry in changes.logs] == [new_log]


def test_read_changes_keeps_the_positions_when_nothing_is_new(reader: sqlite3.Connection) -> None:
    """Return the positions read from, so the next read starts at the same place."""
    changes = read_changes(reader, 7, 3)

    assert not changes
    assert (changes.revision, changes.log_id) == (7, 3)
