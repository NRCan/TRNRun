# ruff: noqa: S101, SLF001

from __future__ import annotations

from collections.abc import Iterator
from pathlib import Path
from threading import Thread
from time import monotonic, sleep
from unittest.mock import Mock

import pytest

import trnrun.client as client_module
from tests.daemon_database import DaemonDatabase
from trnrun.client import DaemonClient
from trnrun.events import LogEvent, SimulationReply, SimulationState

TEST_TIMEOUT = 10.0


class ScriptedProcess:
    """Stand-in `DaemonProcess` that records requests, answers from a script, and owns a database."""

    def __init__(self, database: DaemonDatabase) -> None:
        self.database: DaemonDatabase = database
        self.database_path: Path = database.path
        self.requests: list[dict[str, object]] = []
        self.replies: list[dict[str, object]] = []
        self.exit_error: Mock = Mock(return_value=None)
        self.kill: Mock = Mock()
        self.wait: Mock = Mock()

    def request(self, request: dict[str, object]) -> dict[str, object]:
        """Record the request and return the next scripted reply."""
        self.requests.append(request)
        return self.replies.pop(0) if self.replies else {"ok": True}


@pytest.fixture
def process(tmp_path: Path) -> Iterator[ScriptedProcess]:
    """Return a scripted process whose daemon saved one run before the client started."""
    database = DaemonDatabase(tmp_path / "runs.sqlite3")
    database.submit("earlier")
    yield ScriptedProcess(database)
    database.close()


@pytest.fixture
def factory(monkeypatch: pytest.MonkeyPatch, process: ScriptedProcess) -> Mock:
    """Make every new client talk to the scripted process."""
    factory = Mock(return_value=process)
    monkeypatch.setattr(client_module, "DaemonProcess", factory)
    return factory


@pytest.fixture
def client(factory: Mock) -> Iterator[DaemonClient]:
    """Return a client over the scripted process."""
    del factory
    client = DaemonClient(3, trnrun_path="mock-trnrun.exe", trnrund_path="mock-daemon.exe")
    yield client
    client.kill()


def test_constructor_starts_the_daemon_on_a_new_temporary_database(client: DaemonClient, factory: Mock) -> None:
    """By default, the daemon gets a database of its own in a new directory."""
    database = factory.call_args.args[3]

    factory.assert_called_once_with("mock-daemon.exe", "mock-trnrun.exe", 3, database, overwrite=False)
    assert database.name == "runs.sqlite3"
    assert database.parent.is_dir()
    assert list(database.parent.iterdir()) == []
    assert client._temporary == database.parent


def test_kill_deletes_the_temporary_database(client: DaemonClient, factory: Mock, process: ScriptedProcess) -> None:
    """Killing releases the daemon, then the reader, then the temporary directory."""
    directory = factory.call_args.args[3].parent

    client.kill()
    client.kill()

    assert process.kill.call_count == 2
    assert not directory.exists()
    with pytest.raises(RuntimeError, match="is closed"):
        _ = client.database.pull()


def test_a_given_database_is_used_and_kept(factory: Mock, process: ScriptedProcess) -> None:
    """A database the caller names outlives the client."""
    with DaemonClient(1, database=process.database_path) as client:
        assert client._temporary is None
        assert client.database_path == process.database_path

    factory.assert_called_once_with(
        client_module.BUNDLED_TRNRUND_PATH,
        client_module.BUNDLED_TRNRUN_PATH,
        1,
        process.database_path,
        overwrite=False,
    )
    assert process.database_path.is_file()


def test_overwrite_is_forwarded_to_the_daemon(factory: Mock, process: ScriptedProcess) -> None:
    """The daemon, not Python, owns resetting a persistent database."""
    with DaemonClient(1, database=process.database_path, overwrite=True):
        pass

    factory.assert_called_once_with(
        client_module.BUNDLED_TRNRUND_PATH,
        client_module.BUNDLED_TRNRUN_PATH,
        1,
        process.database_path,
        overwrite=True,
    )
    assert process.database_path.is_file()


def test_startup_failure_deletes_the_temporary_database(monkeypatch: pytest.MonkeyPatch) -> None:
    """A daemon that fails to start leaves no directory behind."""
    failure = RuntimeError("TRNRun daemon exited with code 1")
    factory = Mock(side_effect=failure)
    monkeypatch.setattr(client_module, "DaemonProcess", factory)

    with pytest.raises(RuntimeError) as raised:
        _ = DaemonClient(1)

    assert raised.value is failure
    assert not factory.call_args.args[3].parent.exists()


def test_reader_failure_releases_the_daemon(monkeypatch: pytest.MonkeyPatch, process: ScriptedProcess) -> None:
    """A database the client cannot read stops the daemon it started."""
    monkeypatch.setattr(client_module, "DaemonProcess", Mock(return_value=process))
    process.database_path = process.database_path.with_name("missing.sqlite3")

    with pytest.raises(Exception, match="unable to open database file"):
        _ = DaemonClient(1)

    process.kill.assert_called_once_with()


def test_database_follows_only_runs_saved_after_the_client_started(
    client: DaemonClient,
    process: ScriptedProcess,
) -> None:
    """Runs an earlier daemon saved are skipped; later changes come with their new logs."""
    assert client.database.pull() == {}

    process.database.submit("1")
    process.database.log("1", "Warning", "late", sim_time=5.0)

    assert client.database.pull() == {
        "1": SimulationReply(SimulationState.QUEUED, warnings=1, logs=(LogEvent("Warning", 5.0, message="late"),)),
    }


def test_add_sends_the_deck_and_runner_arguments_and_returns_none(
    client: DaemonClient,
    process: ScriptedProcess,
) -> None:
    """A successful submission needs only an acknowledgement, not a lifecycle state."""
    process.replies.append({"ok": True})

    assert client.add("7", Path("C:/decks/model.dck"), ("--watchTmp:true",)) is None
    assert client.add("8", "model.dck") is None
    assert process.requests == [
        {"cmd": "add", "runId": "7", "deckFile": str(Path("C:/decks/model.dck")), "trnrunArgs": ["--watchTmp:true"]},
        {"cmd": "add", "runId": "8", "deckFile": "model.dck", "trnrunArgs": []},
    ]


@pytest.mark.parametrize("failure", [ValueError("submission rejected"), RuntimeError("daemon exited")])
def test_add_propagates_request_failures(
    client: DaemonClient,
    failure: Exception,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A rejected request or daemon exit must not be treated as a successful submission."""
    monkeypatch.setattr(client._process, "request", Mock(side_effect=failure))

    with pytest.raises(type(failure)) as raised:
        client.add("1", "model.dck")
    assert raised.value is failure


def test_exit_error_comes_from_the_process(client: DaemonClient, process: ScriptedProcess) -> None:
    """The client reports the daemon's exit as the process describes it."""
    assert client.exit_error() is None
    failure = RuntimeError("TRNRun daemon exited with code 1")
    process.exit_error.return_value = failure

    assert client.exit_error() is failure


def test_shutdown_asks_the_daemon_then_waits_and_keeps_the_database(
    client: DaemonClient,
    process: ScriptedProcess,
) -> None:
    """Graceful shutdown is a request, then a wait, never a kill; the final states stay readable."""
    client.shutdown(timeout=2.0)

    assert process.requests == [{"cmd": "shutdown"}]
    process.wait.assert_called_once_with(2.0)
    process.kill.assert_not_called()
    process.database.submit("1")
    assert list(client.database.pull()) == ["1"]


def test_context_exit_kills_the_daemon(client: DaemonClient, process: ScriptedProcess) -> None:
    """Kill sends nothing; leaving the context kills."""
    with client as entered:
        assert entered is client

    process.kill.assert_called_once_with()
    assert process.requests == []


# -----------------------------------------------------------------
# Real daemon
# -----------------------------------------------------------------
def _await_state(client: DaemonClient, run_id: str, state: SimulationState) -> tuple[SimulationReply, list[LogEvent]]:
    """Poll until `run_id` reaches `state`, returning its last change and every log entry the polls returned."""
    deadline = monotonic() + TEST_TIMEOUT
    logs: list[LogEvent] = []
    while True:
        reply = client.database.pull().get(run_id)
        if reply is not None:
            logs.extend(reply.logs)
            if reply.state is state:
                return reply, logs
        assert monotonic() < deadline, f"run {run_id} never reached {state}"
        sleep(0.01)


def test_real_daemon_overwrite_clears_history_and_allows_reusing_ids(tmp_path: Path, fake_trnrun: Path) -> None:
    """A persistent database is preserved by default and reset only by explicit overwrite."""
    deck = tmp_path / "done-overwrite.dck"
    deck.touch()
    database = tmp_path / "runs.sqlite3"

    with DaemonClient(1, database=database, trnrun_path=fake_trnrun) as client:
        client.add("reused", deck)
        client.shutdown(timeout=TEST_TIMEOUT)
        reply = client.database.get("reused")
        assert reply is not None
        assert reply.succeeded
        assert len(client.database.logs("reused")) == 3

    with DaemonClient(1, database=database, trnrun_path=fake_trnrun) as client:
        assert client.database.get("reused") == reply
        assert len(client.database.logs("reused")) == 3
        with pytest.raises(ValueError, match="Invalid or duplicate runId: reused"):
            client.add("reused", deck)

    with DaemonClient(1, database=database, overwrite=True, trnrun_path=fake_trnrun) as client:
        assert client.database.get("reused") is None
        assert client.database.logs("reused") == []
        assert client.database.pull() == {}
        client.add("reused", deck)
        client.shutdown(timeout=TEST_TIMEOUT)
        fresh = client.database.get("reused")
        assert fresh is not None
        assert fresh.succeeded
        assert len(client.database.logs("reused")) == 3

    assert database.is_file()


def test_real_daemon_overwrite_replaces_non_sqlite_files_and_stale_journals(tmp_path: Path, fake_trnrun: Path) -> None:
    """The daemon deletes invalid old files before opening the fresh SQLite database."""
    database = tmp_path / "invalid.sqlite3"
    stale = b"not a SQLite database or journal"
    for suffix in ("", "-wal", "-shm", "-journal"):
        _ = Path(str(database) + suffix).write_bytes(stale)

    with DaemonClient(1, database=database, overwrite=True, trnrun_path=fake_trnrun) as client:
        assert client.database.pull() == {}
        assert database.read_bytes().startswith(b"SQLite format 3")
        assert not Path(str(database) + "-journal").exists()
        for suffix in ("-wal", "-shm"):
            journal = Path(str(database) + suffix)
            if journal.exists():
                assert journal.read_bytes() != stale

    assert database.is_file()


def test_real_daemon_overwrite_refuses_an_owned_database(tmp_path: Path, fake_trnrun: Path) -> None:
    """Overwrite cannot erase a run owned by another live daemon."""
    deck = tmp_path / "done-owner.dck"
    deck.touch()
    database = tmp_path / "owned.sqlite3"

    with DaemonClient(1, database=database, trnrun_path=fake_trnrun) as owner:
        owner.add("owner", deck)
        with (
            pytest.raises(RuntimeError, match="Database is in use by another trnrund"),
            DaemonClient(1, database=database, overwrite=True, trnrun_path=fake_trnrun),
        ):
            pass

        owner.shutdown(timeout=TEST_TIMEOUT)
        reply = owner.database.get("owner")
        assert reply is not None
        assert reply.succeeded
        assert len(owner.database.logs("owner")) == 3


def test_real_daemon_add_acknowledges_and_state_is_read_separately(tmp_path: Path, fake_trnrun: Path) -> None:
    """A successful add returns no state; completion and logs come from the database."""
    deck = tmp_path / "done-ack.dck"
    deck.touch()

    with DaemonClient(1, trnrun_path=fake_trnrun) as client:
        assert client.add("ack", deck) is None
        with pytest.raises(ValueError, match="Invalid or duplicate runId: ack"):
            client.add("ack", deck)

        deadline = monotonic() + TEST_TIMEOUT
        while True:
            if error := client.exit_error():
                raise error
            reply = client.database.get("ack")
            assert reply is not None
            if reply.state is SimulationState.FINISHED:
                break
            assert monotonic() < deadline, "the acknowledged run never finished"
            sleep(0.01)

        assert reply.succeeded
        assert len(client.database.logs("ack")) == reply.notices + reply.warnings + reply.fatals == 3


def test_real_daemon_runs_to_the_end_and_deletes_its_temporary_database(tmp_path: Path, fake_trnrun: Path) -> None:
    """Add and follow a run to its end through the bundled daemon; its run ID stays taken."""
    deck = tmp_path / "done-a.dck"
    deck.touch()

    with DaemonClient(1, trnrun_path=fake_trnrun) as client:
        assert client.add("1", deck) is None
        with pytest.raises(ValueError, match="Invalid or duplicate runId: 1"):
            _ = client.add("1", deck)
        final, logs = _await_state(client, "1", SimulationState.FINISHED)

        assert client.database.pull() == {}
        with pytest.raises(ValueError, match="Invalid or duplicate runId: 1"):
            _ = client.add("1", deck)  # Never reused in the same database.
        directory = client.database_path.parent

    assert final.succeeded
    assert len(logs) == final.notices + final.warnings + final.fatals == 3
    assert not directory.exists()


def test_real_daemon_reuses_a_given_database(tmp_path: Path, fake_trnrun: Path) -> None:
    """A later client on the same database skips earlier runs, which keep their run IDs."""
    deck = tmp_path / "done-a.dck"
    deck.touch()
    database = tmp_path / "runs.sqlite3"

    with DaemonClient(1, database=database, trnrun_path=fake_trnrun) as client:
        _ = client.add("1", deck)
        _ = _await_state(client, "1", SimulationState.FINISHED)

    with DaemonClient(1, database=database, trnrun_path=fake_trnrun) as client:
        assert client.database.pull() == {}
        assert client.database.max_numeric_run_id() == 1
        with pytest.raises(ValueError, match="Invalid or duplicate runId: 1"):
            _ = client.add("1", deck)

    assert database.is_file()


def test_real_daemon_shutdown_finishes_running_runs_before_exiting(tmp_path: Path, fake_trnrun: Path) -> None:
    """Graceful shutdown waits for the running run, which a kill would have stopped, and cancels the queued one."""
    gate = tmp_path / "gate-a.dck"
    queued = tmp_path / "done-b.dck"
    for deck in (gate, queued):
        deck.touch()

    client = DaemonClient(1, trnrun_path=fake_trnrun)
    try:
        _ = client.add("1", gate)
        assert client.add("2", queued) is None
        queued_reply = client.database.get("2")
        assert queued_reply is not None
        assert queued_reply.state is SimulationState.QUEUED
        _ = _await_state(client, "1", SimulationState.RUNNING)

        closing = Thread(target=client.shutdown, daemon=True)
        closing.start()
        closing.join(0.2)
        assert closing.is_alive(), "shutdown returned while a run was still going"

        gate.with_suffix(".release").touch()
        closing.join(TEST_TIMEOUT)
        assert not closing.is_alive()
        final = client.database.pull()
    finally:
        client.kill()

    assert gate.with_suffix(".released").is_file()
    assert client._process._process.returncode == 0
    assert final["1"].succeeded
    assert (final["2"].state, final["2"].error) == (SimulationState.FINISHED, "Not started: the daemon shut down")
    with pytest.raises(RuntimeError, match="daemon closure"):
        _ = client.add("3", queued)
