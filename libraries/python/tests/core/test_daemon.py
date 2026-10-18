"""Tests for ``trnrun.core.daemon``: driving the bundled trnrund and knowing when its database changed.

The daemon is real; TRNRun is Python running decks from ``helpers.write_deck``.
"""

import sqlite3
import time
from collections.abc import Callable, Iterator
from contextlib import closing
from pathlib import Path

import pytest

from tests.helpers import FAILED_EVENTS, PYTHON, release, requires_trnrund, write_deck
from trnrun.core.daemon import Daemon
from trnrun.core.database import connect, parse_log, parse_run, read_changes
from trnrun.core.errors import ClosedError, DaemonExitedError, RequestRejectedError
from trnrun.core.records import SimulationInfo, SimulationState, SimulationStatus
from trnrun.core.settings import SimulationSettings

type StartDaemon = Callable[..., Daemon]

TIMEOUT = 30.0  # Seconds any run gets to reach the state a test waits for.


@pytest.fixture
def start() -> Iterator[StartDaemon]:
    """Return a function starting a daemon on the fake TRNRun; every one started is closed afterwards."""
    started: list[Daemon] = []

    def start(database_path: str | Path | None = None, **kwargs: object) -> Daemon:
        """Start a daemon, by default with a temporary database and two slots."""
        kwargs.setdefault("trnrun_path", PYTHON)
        kwargs.setdefault("max_concurrent", 2)
        daemon = Daemon(database_path, **kwargs)  # ty: ignore[invalid-argument-type]  # pyright: ignore[reportArgumentType]
        started.append(daemon)
        return daemon

    yield start
    for daemon in started:
        daemon.close()


def fetch_run(connection: sqlite3.Connection, run_id: int) -> SimulationInfo | None:
    """Return a run's current row as a record, or None for an unknown ID."""
    row = connection.execute("SELECT * FROM runs WHERE run_id = ?", (run_id,)).fetchone()
    return None if row is None else parse_run(row)


def get_run(daemon: Daemon, run_id: int) -> SimulationInfo | None:
    """Return a run's current row through a connection of its own."""
    with closing(daemon.connect()) as connection:
        return fetch_run(connection, run_id)


def latest_revision(connection: sqlite3.Connection) -> int:
    """Return the largest run revision saved so far, or 0 for an empty database."""
    return int(connection.execute("SELECT coalesce(max(revision), 0) FROM runs").fetchone()[0])


def wait_until(daemon: Daemon, run_id: int, done: Callable[[SimulationInfo], bool]) -> SimulationInfo:
    """Wait for the daemon's changes until run ``run_id`` satisfies ``done``, and return it."""
    deadline = time.monotonic() + TIMEOUT
    with closing(daemon.connect()) as connection:
        while time.monotonic() < deadline:
            # Read before the run, so a save in between wakes the next wait at once.
            revision = latest_revision(connection)
            info = fetch_run(connection, run_id)
            if info is not None and done(info):
                return info
            _ = daemon.wait_for_changes(revision, 0.5)
    raise AssertionError(f"run {run_id} did not reach the expected state within {TIMEOUT} s")


def finished(info: SimulationInfo) -> bool:
    """Return whether the run finished."""
    return info.is_finished


def running(info: SimulationInfo) -> bool:
    """Return whether the run is running."""
    return info.state is SimulationState.RUNNING


# -----------------------------------------------------------------
# Starting and closing
# -----------------------------------------------------------------
def test_missing_trnrund_fails_to_start(tmp_path: Path) -> None:
    """Report a missing trnrund executable by its path."""
    with pytest.raises(FileNotFoundError, match="trnrund executable not found"):
        _ = Daemon(tmp_path / "runs.sqlite3", trnrund_path=tmp_path / "trnrund.exe")


@requires_trnrund
def test_temporary_database_is_deleted_on_close(start: StartDaemon) -> None:
    """Keep the runs in a temporary database, deleted with the daemon."""
    daemon = start()

    assert daemon.database_path.is_file()
    assert (daemon.session_id, daemon.start_revision, daemon.start_log_id) == (1, 0, 0)
    daemon.close()
    daemon.close()  # Safe more than once.

    assert not daemon.database_path.parent.exists()


@requires_trnrund
def test_given_database_is_kept_and_continued(start: StartDaemon, tmp_path: Path) -> None:
    """Continue an existing database in a new session, without losing its runs."""
    path = tmp_path / "runs.sqlite3"
    deck = write_deck(tmp_path / "model.dck")
    with start(path) as first:
        first_run = first.add(deck)
        _ = wait_until(first, first_run, finished)
        first.shutdown()
    assert path.is_file()

    with start(path) as second, closing(second.connect()) as connection:
        assert second.database_path == path
        assert second.session_id == 2
        assert second.start_revision > 0
        assert second.start_log_id == 3
        assert not read_changes(connection, second.start_revision, second.start_log_id)  # Only new changes.

        second_run = second.add(deck)

        assert second_run == first_run + 1
        assert [row["run_id"] for row in connection.execute("SELECT run_id FROM runs WHERE session_id = 1")] == [
            first_run,
        ]
        assert second.wait_for_changes(second.start_revision, TIMEOUT) is True
        changes = read_changes(connection, second.start_revision, second.start_log_id)
        assert [info.run_id for info in changes.runs] == [second_run]


@requires_trnrund
def test_database_in_use_fails_with_trnrund_message(start: StartDaemon, tmp_path: Path) -> None:
    """Raise trnrund's startup error, such as a database held by another daemon."""
    path = tmp_path / "runs.sqlite3"
    _ = start(path)

    with pytest.raises(DaemonExitedError, match="in use by another trnrund"):
        _ = start(path)


@requires_trnrund
def test_context_manager_interrupts_unfinished_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Save unfinished runs as interrupted when leaving the with block."""
    path = tmp_path / "runs.sqlite3"
    deck = write_deck(tmp_path / "gate.dck", gated=True)
    with start(path) as daemon:
        run_id = daemon.add(deck)
        _ = wait_until(daemon, run_id, running)

    with closing(connect(path)) as connection:
        info = fetch_run(connection, run_id)

    assert info is not None
    assert info.is_finished
    assert (info.status, info.status_message) == (SimulationStatus.CANCELLED, "Interrupted")
    assert info.error == "Interrupted: the client disconnected"


# -----------------------------------------------------------------
# Adding runs
# -----------------------------------------------------------------
@requires_trnrund
def test_added_run_is_followed_to_success(start: StartDaemon, tmp_path: Path) -> None:
    """Report a run's events, logs and outcome as trnrund saves them."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "model.dck"), ["--pollMs:10"], label="baseline")

    info = wait_until(daemon, run_id, finished)

    assert info.succeeded is True
    assert (info.exit_code, info.error) == (0, None)
    assert info.label == "baseline"
    assert info.session_id == daemon.session_id
    assert info.trnrun_args == ["--pollMs:10"]
    assert info.deck_file == tmp_path / "model.dck"
    assert (info.status, info.status_message) == (SimulationStatus.DONE, "")  # TRNRun sent an empty message.
    assert info.config is not None
    assert info.config.stop == 10.0
    assert info.progress is not None
    assert info.progress.percent == 1.0
    assert (info.notices, info.warnings, info.fatals) == (1, 1, 1)
    assert info.submitted_at is not None
    assert info.started_at is not None
    assert info.finished_at is not None
    with closing(daemon.connect()) as connection:
        rows = connection.execute("SELECT * FROM logs WHERE run_id = ? ORDER BY log_id", (run_id,)).fetchall()
    logs = [parse_log(row) for row in rows]
    assert [(log.severity, log.message) for log in logs] == [
        ("Notice", "first"),
        ("Warning", "second"),
        ("Fatal", "third"),
    ]
    assert (logs[1].unit_id, logs[1].type_id, logs[1].message_code, logs[1].information) == (7, 56, 123, "details")


@requires_trnrund
def test_wait_for_changes_and_read_changes_return_every_change_once(start: StartDaemon, tmp_path: Path) -> None:
    """Hand out each saved change once, ending with the finished run and all its logs."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "model.dck"))
    runs: list[SimulationInfo] = []
    log_ids: list[int] = []
    revision, log_id = daemon.start_revision, daemon.start_log_id
    deadline = time.monotonic() + TIMEOUT
    with closing(daemon.connect()) as connection:
        while not (runs and runs[-1].is_finished) and time.monotonic() < deadline:
            if daemon.wait_for_changes(revision, 0.5):
                changes = read_changes(connection, revision, log_id)
                revision, log_id = changes.revision, changes.log_id
                runs.extend(changes.runs)
                log_ids.extend(log.log_id for log in changes.logs)

        assert not read_changes(connection, revision, log_id)

    assert runs[-1].run_id == run_id
    assert runs[-1].is_finished
    assert [info.revision for info in runs] == sorted({info.revision for info in runs})
    assert log_ids == [1, 2, 3]
    assert daemon.wait_for_changes(revision, 0.1) is False


@requires_trnrund
def test_failed_run_is_reported(start: StartDaemon, tmp_path: Path) -> None:
    """Keep TRNRun's ERROR status and exit code for a failed run."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "failed.dck", FAILED_EVENTS, exit_code=1))

    info = wait_until(daemon, run_id, finished)

    assert info.succeeded is False
    assert info.exit_code == 1
    assert (info.status, info.status_message) == (SimulationStatus.ERROR, "Fake failure")


@requires_trnrund
def test_run_without_terminal_status_is_an_error(start: StartDaemon, tmp_path: Path) -> None:
    """Give a run that exits without a terminal status a daemon-owned ERROR."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "silent.dck", []))

    info = wait_until(daemon, run_id, finished)

    assert info.succeeded is False
    assert info.exit_code == 0
    assert (info.status, info.status_message) == (SimulationStatus.ERROR, "TRNRun exited without a terminal status")


@requires_trnrund
def test_relative_deck_resolves_from_the_working_directory(
    start: StartDaemon,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Resolve a relative deck here, not from the daemon's working directory."""
    _ = write_deck(tmp_path / "model.dck")
    monkeypatch.chdir(tmp_path)
    daemon = start()

    run_id = daemon.add("model.dck")

    info = get_run(daemon, run_id)
    assert info is not None
    assert info.deck_file == tmp_path / "model.dck"


@requires_trnrund
def test_every_simulation_setting_is_accepted(start: StartDaemon, tmp_path: Path) -> None:
    """Keep ``SimulationSettings`` flags accepted by TRNRun's parser inside trnrund."""
    daemon = start()
    settings = SimulationSettings(
        trnexe_path=PYTHON,
        gui_visibility="hidden",
        wait_for_gui=False,
        wait_for_lst=False,
        wait_for_tmp=False,
        detect_timeout_ms=1_000,
        extra_delay_ms=0,
        poll_ms=10,
        watch_log=True,
        watch_tmp=True,
        watch_timeout_ms=5_000,
        stall_timeout_ms=3_000,
        clean_on_success=False,
        kill_on_timeout=True,
        kill_on_stall=True,
        severity="Warning",
        write_events=False,
    )

    run_id = daemon.add(write_deck(tmp_path / "model.dck"), settings)

    info = get_run(daemon, run_id)
    assert info is not None
    assert info.trnrun_args == settings.to_cli_args()


@requires_trnrund
@pytest.mark.parametrize(
    ("deck_name", "args", "message"),
    [
        ("missing.dck", [], "Deck file not found"),
        ("model.txt", [], "Expected .dck or .trd"),
        ("model.dck", ["--bogus:1"], "Unknown option"),
        ("model.dck", ["--pollMs:fast"], "Invalid value"),
        ("model.dck", ["--runId:3"], "not allowed"),
        ("model.dck", ["extra"], "Unexpected argument"),
    ],
)
def test_invalid_run_is_rejected(
    start: StartDaemon,
    tmp_path: Path,
    deck_name: str,
    args: list[str],
    message: str,
) -> None:
    """Reject a run trnrund or TRNRun would refuse, when it is added."""
    for name in ("model.dck", "model.txt"):
        _ = write_deck(tmp_path / name)
    daemon = start()

    with pytest.raises(RequestRejectedError, match=message):
        _ = daemon.add(tmp_path / deck_name, args)

    with closing(daemon.connect()) as connection:
        assert connection.execute("SELECT count(*) FROM runs").fetchone()[0] == 0


# -----------------------------------------------------------------
# Cancelling
# -----------------------------------------------------------------
@requires_trnrund
def test_cancel_queued_and_running_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Finish a queued run on return, and a running one once it is killed."""
    daemon = start(max_concurrent=1)
    gate = write_deck(tmp_path / "gate.dck", gated=True)
    running_id = daemon.add(gate)
    queued_id = daemon.add(write_deck(tmp_path / "model.dck"))
    _ = wait_until(daemon, running_id, running)

    daemon.cancel(queued_id)

    queued = get_run(daemon, queued_id)
    assert queued is not None
    assert queued.is_finished
    assert queued.started_at is None
    assert (queued.status, queued.status_message) == (SimulationStatus.CANCELLED, "Not started")
    assert queued.error == "Not started: cancelled by the client"

    daemon.cancel(running_id)
    cancelled = wait_until(daemon, running_id, finished)

    assert (cancelled.status, cancelled.status_message) == (SimulationStatus.CANCELLED, "Interrupted")
    assert cancelled.error == "Interrupted: cancelled by the client"
    assert cancelled.succeeded is False


@requires_trnrund
def test_cancel_leaves_a_finished_run_unchanged(start: StartDaemon, tmp_path: Path) -> None:
    """Keep a finished run's real outcome."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "model.dck"))
    before = wait_until(daemon, run_id, finished)

    daemon.cancel(run_id)

    assert get_run(daemon, run_id) == before


@requires_trnrund
def test_cancel_unknown_run_is_rejected(start: StartDaemon) -> None:
    """Reject a run ID trnrund never assigned."""
    daemon = start()

    with pytest.raises(RequestRejectedError, match="999"):
        daemon.cancel(999)


# -----------------------------------------------------------------
# Shutting down
# -----------------------------------------------------------------
@requires_trnrund
def test_shutdown_waits_for_running_runs_and_cancels_queued_ones(start: StartDaemon, tmp_path: Path) -> None:
    """Let a running run finish, never start a queued one, then exit cleanly."""
    daemon = start(max_concurrent=1)
    gate = write_deck(tmp_path / "gate.dck", gated=True)
    running_id = daemon.add(gate)
    queued_id = daemon.add(write_deck(tmp_path / "model.dck"))
    _ = wait_until(daemon, running_id, running)
    release(gate)

    daemon.shutdown(timeout=TIMEOUT)

    done = get_run(daemon, running_id)
    queued = get_run(daemon, queued_id)
    assert done is not None
    assert done.succeeded is True
    assert queued is not None
    assert (queued.status, queued.status_message) == (SimulationStatus.CANCELLED, "Not started")
    assert queued.error == "Not started: the daemon shut down"


@requires_trnrund
def test_shutdown_cancel_running_kills_running_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Kill running runs at once with ``cancel_running``."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "gate.dck", gated=True))
    _ = wait_until(daemon, run_id, running)

    daemon.shutdown(cancel_running=True, timeout=TIMEOUT)

    info = get_run(daemon, run_id)
    assert info is not None
    assert (info.status, info.status_message) == (SimulationStatus.CANCELLED, "Interrupted")


@requires_trnrund
def test_shutdown_timeout_interrupts_running_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Close stdin once the timeout passes, saving running runs as interrupted."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "gate.dck", gated=True))
    _ = wait_until(daemon, run_id, running)

    daemon.shutdown(timeout=0.2)

    info = get_run(daemon, run_id)
    assert info is not None
    assert info.is_finished
    assert info.error == "Interrupted: the client disconnected"


@requires_trnrund
def test_after_shutdown_reads_work_and_requests_fail(start: StartDaemon, tmp_path: Path) -> None:
    """Keep the database readable, stop blocking in wait_for_changes(), and refuse new requests."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "model.dck"))
    daemon.shutdown(timeout=TIMEOUT)

    started = time.monotonic()
    assert daemon.wait_for_changes(daemon.start_revision) is True
    with closing(daemon.connect()) as connection:
        changes = read_changes(connection, daemon.start_revision, daemon.start_log_id)
    with pytest.raises(ClosedError, match="trnrund is closed"):
        _ = daemon.wait_for_changes(changes.revision)

    assert time.monotonic() - started < 5.0
    assert [info.run_id for info in changes.runs] == [run_id]
    with pytest.raises(ClosedError, match="trnrund is closed"):
        _ = daemon.add(tmp_path / "model.dck")


# -----------------------------------------------------------------
# Following changes
# -----------------------------------------------------------------
@requires_trnrund
def test_wait_for_changes_times_out_with_no_changes(start: StartDaemon) -> None:
    """Return False when nothing is saved within the timeout."""
    daemon = start()

    assert daemon.wait_for_changes(daemon.start_revision, 0.1) is False


@requires_trnrund
def test_wait_for_changes_announces_saved_revisions(start: StartDaemon, tmp_path: Path) -> None:
    """Wake a reader once a later revision is saved."""
    daemon = start()
    _ = daemon.add(write_deck(tmp_path / "model.dck"))

    assert daemon.wait_for_changes(0, TIMEOUT) is True


@requires_trnrund
def test_wait_for_changes_after_close_does_not_block(start: StartDaemon, tmp_path: Path) -> None:
    """Know the final revision even once a temporary database is deleted, then raise ClosedError."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "model.dck"))
    _ = wait_until(daemon, run_id, finished)
    with closing(daemon.connect()) as connection:
        final = read_changes(connection).revision

    daemon.close()

    assert not daemon.database_path.exists()
    assert daemon.wait_for_changes(0, TIMEOUT) is True
    with pytest.raises(ClosedError, match="trnrund is closed"):
        _ = daemon.wait_for_changes(final, TIMEOUT)


@requires_trnrund
def test_crash_is_raised_after_its_changes(start: StartDaemon, tmp_path: Path) -> None:
    """Announce what a killed trnrund saved, then raise its exit instead of hanging."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "gate.dck", gated=True))
    _ = wait_until(daemon, run_id, running)

    revision = daemon.start_revision
    with closing(daemon.connect()) as connection:  # Opened before the crash, as a reader would be.
        daemon._process._popen.kill()
        with pytest.raises(DaemonExitedError, match="trnrund exited with code 1") as raised:  # noqa: PT012 - drains first
            for _ in range(100):
                if daemon.wait_for_changes(revision, 0.5):
                    revision = read_changes(connection, revision).revision
        final = latest_revision(connection)

    assert raised.value.exit_code == 1
    assert revision == final  # Every saved change was read before the error.
