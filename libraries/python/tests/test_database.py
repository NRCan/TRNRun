"""Tests for ``trnrun.database``: the read-only view of a trnrund database."""

import sqlite3
from collections.abc import Iterator
from pathlib import Path

import pytest

from tests.helpers import create_database, insert_log, insert_run, update_run
from trnrun.database import Database
from trnrun.runs import SimulationState


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
def database(path: Path) -> Iterator[Database]:
    """Return the database opened read-only."""
    with Database(path) as database:
        yield database


# -----------------------------------------------------------------
# Opening and closing
# -----------------------------------------------------------------
def test_open_records_an_absolute_path(path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Resolve a relative path from the current working directory."""
    monkeypatch.chdir(path.parent)

    with Database(path.name) as database:
        assert database.path == path
        assert database.path.is_absolute()


def test_open_missing_database_fails(tmp_path: Path) -> None:
    """Never create a database: trnrund owns it."""
    with pytest.raises(sqlite3.OperationalError):
        _ = Database(tmp_path / "missing.sqlite3")
    assert not (tmp_path / "missing.sqlite3").exists()


def test_open_rejects_another_schema_version_and_closes(tmp_path: Path) -> None:
    """Refuse a database this package cannot read, without leaving it open."""
    path = tmp_path / "old.sqlite3"
    create_database(path, version=2).close()

    with pytest.raises(ValueError, match="Unsupported TRNRun database schema 2; expected 3"):
        _ = Database(path)
    path.unlink()  # Fails on Windows while a connection still holds the file.


def test_database_is_read_only(database: Database) -> None:
    """Never let a reader write to trnrund's database."""
    with pytest.raises(sqlite3.OperationalError, match="readonly"):
        _ = database.execute("INSERT INTO sessions (started_at) VALUES ('now')")


def test_close_is_idempotent_and_ends_queries(path: Path) -> None:
    """Close once on leaving the with block, and allow closing again."""
    with Database(path) as database:
        pass
    database.close()

    with pytest.raises(sqlite3.ProgrammingError):
        _ = database.get_run(1)


# -----------------------------------------------------------------
# Following changes
# -----------------------------------------------------------------
def test_poll_returns_everything_then_only_what_is_new(writer: sqlite3.Connection, database: Database) -> None:
    """Advance past each poll's runs and logs, so nothing is returned twice."""
    first = insert_run(writer)
    second = insert_run(writer)
    log = insert_log(writer, first, message="hello")

    changes = database.poll()

    assert [info.run_id for info in changes.runs] == [first, second]
    assert [entry.log_id for entry in changes.logs] == [log]
    assert (database.revision, database.log_id) == (2, log)
    assert not database.poll()

    update_run(writer, first, state="RUNNING")
    later_log = insert_log(writer, first, severity="Warning")

    changes = database.poll()

    assert [(info.run_id, info.state) for info in changes.runs] == [(first, SimulationState.RUNNING)]
    assert [entry.log_id for entry in changes.logs] == [later_log]


def test_poll_returns_the_latest_snapshot_in_change_order(writer: sqlite3.Connection, database: Database) -> None:
    """Return each run once, at its latest revision, ordered by when it last changed."""
    first = insert_run(writer)
    second = insert_run(writer)
    update_run(writer, first, state="RUNNING")
    update_run(writer, first, state="FINISHED", trnrun_status="DONE", succeeded=1, exit_code=0)

    changes = database.poll()

    assert [info.run_id for info in changes.runs] == [second, first]
    assert changes.runs[-1].state is SimulationState.FINISHED
    assert changes.runs[-1].revision == database.revision == 4


def test_poll_starts_after_the_given_revision_and_log(writer: sqlite3.Connection, path: Path) -> None:
    """Skip the history before ``after_revision`` and ``after_log_id``."""
    old = insert_run(writer)
    old_log = insert_log(writer, old)
    new = insert_run(writer)
    new_log = insert_log(writer, new)

    with Database(path, after_revision=1, after_log_id=old_log) as database:
        changes = database.poll()

    assert [info.run_id for info in changes.runs] == [new]
    assert [entry.log_id for entry in changes.logs] == [new_log]


def test_seek_end_skips_the_history(writer: sqlite3.Connection, database: Database) -> None:
    """Return only what is saved after ``seek_end``."""
    run_id = insert_run(writer)
    _ = insert_log(writer, run_id)

    database.seek_end()

    assert (database.revision, database.log_id) == (1, 1)
    assert not database.poll()
    update_run(writer, run_id, state="RUNNING")
    assert [info.revision for info in database.poll().runs] == [2]


def test_seek_end_of_an_empty_database(database: Database) -> None:
    """Start from zero when nothing was saved yet."""
    database.seek_end()

    assert (database.revision, database.log_id) == (0, 0)


# -----------------------------------------------------------------
# Queries
# -----------------------------------------------------------------
def test_get_run(writer: sqlite3.Connection, database: Database) -> None:
    """Return a run's current snapshot, or None for an unknown ID."""
    run_id = insert_run(writer, label="baseline")
    update_run(writer, run_id, state="RUNNING")

    info = database.get_run(run_id)

    assert info is not None
    assert (info.label, info.state, info.revision) == ("baseline", SimulationState.RUNNING, 2)
    assert database.get_run(999) is None


def test_get_logs(writer: sqlite3.Connection, database: Database) -> None:
    """Return a run's logs oldest first, without other runs' logs."""
    first = insert_run(writer)
    second = insert_run(writer)
    a = insert_log(writer, first, message="a")
    _ = insert_log(writer, second, message="other")
    b = insert_log(writer, first, message="b")

    assert [log.log_id for log in database.get_logs(first)] == [a, b]
    assert [log.message for log in database.get_logs(first)] == ["a", "b"]
    assert database.get_logs(999) == []


def test_get_runs_filters_by_session_and_state(writer: sqlite3.Connection, database: Database) -> None:
    """Combine the optional filters, and order by last change."""
    a = insert_run(writer, session_id=1, state="FINISHED")
    b = insert_run(writer, session_id=2, state="QUEUED")
    c = insert_run(writer, session_id=2, state="FINISHED")
    update_run(writer, a, label="touched")  # Now the latest change.

    assert [info.run_id for info in database.get_runs()] == [b, c, a]
    assert [info.run_id for info in database.get_runs(session_id=2)] == [b, c]
    assert [info.run_id for info in database.get_runs(state=SimulationState.FINISHED)] == [c, a]
    assert [info.run_id for info in database.get_runs(session_id=2, state=SimulationState.FINISHED)] == [c]
    assert database.get_runs(session_id=3) == []


def test_count_runs_by_state(writer: sqlite3.Connection, database: Database) -> None:
    """Count every state, including those without runs, overall or per session."""
    _ = insert_run(writer, session_id=1, state="FINISHED")
    _ = insert_run(writer, session_id=2, state="FINISHED")
    _ = insert_run(writer, session_id=2, state="RUNNING")

    assert database.count_runs_by_state() == {
        SimulationState.QUEUED: 0,
        SimulationState.RUNNING: 1,
        SimulationState.FINISHED: 2,
    }
    assert database.count_runs_by_state(session_id=1) == {
        SimulationState.QUEUED: 0,
        SimulationState.RUNNING: 0,
        SimulationState.FINISHED: 1,
    }


def test_count_runs_by_state_of_an_empty_database(database: Database) -> None:
    """Report zero for every state."""
    assert database.count_runs_by_state() == dict.fromkeys(SimulationState, 0)


def test_execute_returns_rows_by_column_name(writer: sqlite3.Connection, database: Database) -> None:
    """Run a custom query with bound parameters and named columns."""
    run_id = insert_run(writer, label="custom")

    row = database.execute("SELECT run_id, label FROM runs WHERE label = ?", ("custom",)).fetchone()

    assert (row["run_id"], row["label"]) == (run_id, "custom")
