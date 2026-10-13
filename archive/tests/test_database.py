# ruff: noqa: D103, S101

from __future__ import annotations

import sqlite3
from collections.abc import Callable, Iterator
from pathlib import Path
from threading import Event, Thread
from unittest.mock import Mock

import pytest

from tests.daemon_database import DaemonDatabase
from trnrun.database import RunDatabase
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SettingEvent,
    SimulationReply,
    SimulationState,
    SimulationStatus,
    StatusEvent,
)

# Saved by trnrund from a fake TRNRun's SETTING event.
SETTING_PAYLOAD: dict[str, object] = {
    "trnexePath": r"C:\TRNSYS18\Exe\TrnEXE64.exe",
    "guiVisibility": "hidden",
    "waitForGui": True,
    "waitForLst": False,
    "waitForTmp": True,
    "detectTimeoutMs": 300_000,
    "extraDelayMs": 25,
    "watchLog": True,
    "watchTmp": False,
    "watchTimeoutMs": 1_000,
    "stallTimeoutMs": 2_000,
    "pollMs": 100,
    "cleanOnSuccess": False,
    "killOnTimeout": True,
    "killOnStall": False,
    "severity": "Warning",
    "writeEvents": True,
}


@pytest.fixture
def daemon(tmp_path: Path) -> Iterator[DaemonDatabase]:
    """Return a database written as trnrund writes it."""
    database = DaemonDatabase(tmp_path / "runs.sqlite3")
    yield database
    database.close()


@pytest.fixture
def reader(daemon: DaemonDatabase) -> Iterator[RunDatabase]:
    """Return a reader of every run in the daemon's database."""
    with RunDatabase(daemon.path) as database:
        yield database


def test_a_queued_run_has_no_events_yet(daemon: DaemonDatabase, reader: RunDatabase) -> None:
    daemon.submit("1")

    assert reader.pull() == {"1": SimulationReply(SimulationState.QUEUED)}


def test_pull_reads_every_reported_event(daemon: DaemonDatabase, reader: RunDatabase) -> None:
    daemon.submit("1")
    daemon.update(
        "1",
        state="RUNNING",
        trnrun_status="RUNNING",
        trnrun_message="started",
        start_time=0.0,
        stop_time=8760.0,
        time_step=0.25,
        percent=0.25,
        sim_time=2.0,
        elapsed_ms=1500.0,
        eta_ms=4500.5,
        setting=SETTING_PAYLOAD,
    )

    assert reader.pull()["1"] == SimulationReply(
        SimulationState.RUNNING,
        status=StatusEvent(SimulationStatus.RUNNING, "started"),
        config=ConfigEvent(0.0, 8760.0, 0.25),
        progress=ProgressEvent(2.0, 0.25, 1500.0, 4500.5),
        setting=SettingEvent(
            trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe",
            gui_visibility="hidden",
            wait_for_gui=True,
            wait_for_lst=False,
            wait_for_tmp=True,
            detect_timeout_ms=300_000,
            extra_delay_ms=25,
            watch_log=True,
            watch_tmp=False,
            watch_timeout_ms=1_000,
            stall_timeout_ms=2_000,
            poll_ms=100,
            clean_on_success=False,
            kill_on_timeout=True,
            kill_on_stall=False,
            severity="Warning",
            write_events=True,
        ),
    )


@pytest.mark.parametrize(
    ("finish", "expected"),
    [
        ({}, SimulationReply(SimulationState.FINISHED, 0, status=StatusEvent(SimulationStatus.DONE), succeeded=True)),
        (
            {"status": "ERROR", "exit_code": None, "error": "launch failed"},
            SimulationReply(
                SimulationState.FINISHED,
                None,
                "launch failed",
                status=StatusEvent(SimulationStatus.ERROR),
            ),
        ),
        (
            {"exit_code": 7},
            SimulationReply(SimulationState.FINISHED, 7, status=StatusEvent(SimulationStatus.DONE)),
        ),
    ],
)
def test_pull_reads_the_outcome(
    daemon: DaemonDatabase,
    reader: RunDatabase,
    finish: dict[str, object],
    expected: SimulationReply,
) -> None:
    daemon.submit("1")
    daemon.finish("1", **finish)  # pyright: ignore[reportArgumentType]

    assert reader.pull()["1"] == expected


def test_pull_returns_each_change_once_with_only_new_logs(daemon: DaemonDatabase, reader: RunDatabase) -> None:
    daemon.submit("1")
    daemon.submit("2")
    daemon.log("1", "Notice", "one", sim_time=1.0)
    daemon.log("1", "Fatal", "two", unit_id=3, type_id=56, message_code=42, information="x")
    first = reader.pull()

    assert list(first) == ["2", "1"]  # In the order they last changed.
    assert first["1"].logs == (LogEvent("Notice", 1.0, message="one"), LogEvent("Fatal", 0.0, 3, 56, 42, "two", "x"))
    assert (first["1"].notices, first["1"].fatals) == (1, 1)
    assert first["2"].logs == ()
    assert reader.pull() == {}

    daemon.log("1", "Warning", "three")
    daemon.finish("1")
    final = reader.pull()

    assert list(final) == ["1"]
    assert final["1"].logs == (LogEvent("Warning", 0.0, message="three"),)
    assert (final["1"].notices, final["1"].warnings, final["1"].fatals) == (1, 1, 1)


def test_skip_existing_pulls_only_later_changes(daemon: DaemonDatabase) -> None:
    daemon.submit("1")
    daemon.log("1")
    daemon.submit("2")

    with RunDatabase(daemon.path, skip_existing=True) as reader:
        assert reader.pull() == {}
        daemon.log("2", message="new")
        assert {run_id: reply.logs for run_id, reply in reader.pull().items()} == {
            "2": (LogEvent("Notice", 0.0, message="new"),),
        }


def test_max_numeric_run_id_ignores_other_ids(daemon: DaemonDatabase, reader: RunDatabase) -> None:
    assert reader.max_numeric_run_id() == 0

    for run_id in ("2", "10", "x11", "12b", "batch-99"):
        daemon.submit(run_id)

    assert reader.max_numeric_run_id() == 10


def test_another_schema_version_is_refused(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    database = DaemonDatabase(tmp_path / "old.sqlite3", version=1)
    connection = sqlite3.connect(database.path)
    monkeypatch.setattr(sqlite3, "connect", Mock(return_value=connection))
    try:
        with pytest.raises(ValueError, match="has schema version 1; this trnrun reads 2"):
            _ = RunDatabase(database.path)
        with pytest.raises(sqlite3.ProgrammingError, match="closed"):
            _ = connection.execute("SELECT 1")
    finally:
        connection.close()
        database.close()


def test_a_missing_database_is_not_created(tmp_path: Path) -> None:
    with pytest.raises(sqlite3.OperationalError):
        _ = RunDatabase(tmp_path / "missing.sqlite3")

    assert not (tmp_path / "missing.sqlite3").exists()


def test_the_database_is_read_only(daemon: DaemonDatabase, reader: RunDatabase) -> None:
    del daemon
    with pytest.raises(sqlite3.OperationalError, match="readonly"):
        _ = reader._connection.execute("DELETE FROM runs")  # pyright: ignore[reportOptionalMemberAccess]  # noqa: SLF001


@pytest.mark.parametrize(
    "read",
    [
        lambda database: database.pull(),
        lambda database: database.get("1"),
        lambda database: database.logs("1"),
        lambda database: database.max_numeric_run_id(),
    ],
    ids=["pull", "get", "logs", "max-numeric-run-id"],
)
def test_a_closed_database_refuses_reads(reader: RunDatabase, read: Callable[[RunDatabase], object]) -> None:
    reader.close()
    reader.close()

    with pytest.raises(RuntimeError, match="is closed"):
        _ = read(reader)


def test_an_unknown_state_fails_loudly(daemon: DaemonDatabase, reader: RunDatabase) -> None:
    """A database from another daemon version is not silently accepted."""
    daemon.submit("1")
    daemon.update("1", trnrun_status="FUTURE")

    with pytest.raises(ValueError, match="'FUTURE' is not a valid SimulationStatus"):
        _ = reader.pull()


def test_reads_use_query_snapshots_without_explicit_transactions(daemon: DaemonDatabase, reader: RunDatabase) -> None:
    """Completed reads release their snapshot, so later reads see new saves."""
    statements: list[str] = []
    reader._connection.set_trace_callback(statements.append)  # noqa: SLF001
    daemon.submit("1")

    assert reader.get("missing") is None
    assert reader.pull() == {"1": SimulationReply(SimulationState.QUEUED)}
    assert reader.get("1") == SimulationReply(SimulationState.QUEUED)
    assert reader.logs("1") == []
    assert reader.max_numeric_run_id() == 1

    daemon.log("1", "Warning", "new")
    daemon.finish("1")
    assert reader.logs("1") == [LogEvent("Warning", 0.0, message="new")]
    reply = reader.get("1")
    assert reply is not None
    assert reply.state is SimulationState.FINISHED
    assert reader.pull() == {"1": reply}
    assert not reader._connection.in_transaction  # noqa: SLF001
    assert not any(sql.split()[0].upper() in {"BEGIN", "COMMIT", "ROLLBACK"} for sql in statements)


def test_parse_failure_does_not_advance_the_pull_cursor(daemon: DaemonDatabase, reader: RunDatabase) -> None:
    """A failed pull must not skip successfully parsed rows preceding the bad row."""
    daemon.submit("1")
    daemon.submit("2")
    daemon.update("2", trnrun_status="FUTURE")

    with pytest.raises(ValueError, match="'FUTURE' is not a valid SimulationStatus"):
        _ = reader.pull()

    daemon.update("2", trnrun_status="RUNNING")
    assert list(reader.pull()) == ["1", "2"]
    assert reader.pull() == {}


def test_context_exit_closes_the_connection(daemon: DaemonDatabase) -> None:
    with RunDatabase(daemon.path) as database:
        connection = database._connection  # noqa: SLF001
        assert database.pull() == {}

    with pytest.raises(sqlite3.ProgrammingError, match="closed"):
        _ = connection.execute("SELECT 1")
    database.close()


def test_close_waits_for_an_active_read(reader: RunDatabase) -> None:
    """Removing explicit transactions must not let close interrupt another thread's read."""
    closing, closed = Event(), Event()

    def close() -> None:
        closing.set()
        reader.close()
        closed.set()

    thread = Thread(target=close, daemon=True)
    with reader._read():  # noqa: SLF001
        thread.start()
        assert closing.wait(2.0)
        assert not closed.wait(0.05)

    thread.join(2.0)
    assert not thread.is_alive()
    assert closed.is_set()
