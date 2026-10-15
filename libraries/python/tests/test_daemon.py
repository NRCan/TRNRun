"""Tests for ``trnrun.daemon``: driving the bundled trnrund and following its runs.

The daemon is real; TRNRun is Python running decks from ``helpers.write_deck``.
"""

import time
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

from tests.helpers import FAILED_EVENTS, PYTHON, release, requires_trnrund, write_deck
from trnrun.daemon import Daemon, _field
from trnrun.database import Database
from trnrun.events import SimulationStatus, StatusEvent
from trnrun.runs import SimulationInfo, SimulationState
from trnrun.settings import SimulationSettings

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


def wait_until(daemon: Daemon, run_id: int, done: Callable[[SimulationInfo], bool]) -> SimulationInfo:
    """Follow the daemon's changes until run ``run_id`` satisfies ``done``, and return it."""
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        info = daemon.database.get_run(run_id)
        if info is not None and done(info):
            return info
        _ = daemon.wait(0.5)
    raise AssertionError(f"run {run_id} did not reach the expected state within {TIMEOUT} s")


def finished(info: SimulationInfo) -> bool:
    """Return whether the run finished."""
    return info.is_finished


def running(info: SimulationInfo) -> bool:
    """Return whether the run is running."""
    return info.state is SimulationState.RUNNING


# -----------------------------------------------------------------
# Reply fields
# -----------------------------------------------------------------
def test_field_returns_a_value_of_the_expected_type() -> None:
    """Read a reply field that has the expected type."""
    assert _field({"ok": True, "runId": 3}, "runId", int) == 3


@pytest.mark.parametrize("reply", [{"ok": True}, {"ok": True, "runId": "3"}])
def test_field_rejects_a_missing_or_mistyped_value(reply: dict[str, object]) -> None:
    """Report a reply trnrund should not have sent as a protocol error."""
    with pytest.raises(RuntimeError, match="trnrund reply has no int 'runId'"):
        _ = _field(reply, "runId", int)


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

    with start(path) as second:
        assert second.database_path == path
        assert second.session_id == 2
        assert second.start_revision > 0
        assert second.start_log_id == 3
        assert not second.poll()  # Only this daemon's changes.

        second_run = second.add(deck)

        assert second_run == first_run + 1
        assert [info.run_id for info in second.database.get_runs(session_id=1)] == [first_run]
        assert [info.run_id for info in second.wait(TIMEOUT).runs] == [second_run]


@requires_trnrund
def test_database_in_use_fails_with_trnrund_message(start: StartDaemon, tmp_path: Path) -> None:
    """Raise trnrund's startup error, such as a database held by another daemon."""
    path = tmp_path / "runs.sqlite3"
    _ = start(path)

    with pytest.raises(RuntimeError, match="in use by another trnrund"):
        _ = start(path)


@requires_trnrund
def test_context_manager_interrupts_unfinished_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Save unfinished runs as interrupted when leaving the with block."""
    path = tmp_path / "runs.sqlite3"
    deck = write_deck(tmp_path / "gate.dck", gated=True)
    with start(path) as daemon:
        run_id = daemon.add(deck)
        _ = wait_until(daemon, run_id, running)

    with Database(path) as database:
        info = database.get_run(run_id)

    assert info is not None
    assert info.is_finished
    assert info.status == StatusEvent(SimulationStatus.CANCELLED, "Interrupted")
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

    assert info.succeeded
    assert (info.exit_code, info.error) == (0, "")
    assert info.label == "baseline"
    assert info.session_id == daemon.session_id
    assert info.trnrun_args == ["--pollMs:10"]
    assert info.deck_file == tmp_path / "model.dck"
    assert info.status == StatusEvent(SimulationStatus.DONE)
    assert info.config is not None
    assert info.config.stop == 10.0
    assert info.progress is not None
    assert info.progress.percent == 1.0
    assert (info.notices, info.warnings, info.fatals) == (1, 1, 1)
    assert info.submitted_at is not None
    assert info.started_at is not None
    assert info.finished_at is not None
    logs = daemon.database.get_logs(run_id)
    assert [(log.severity, log.message) for log in logs] == [
        ("Notice", "first"),
        ("Warning", "second"),
        ("Fatal", "third"),
    ]
    assert (logs[1].unit_id, logs[1].type_id, logs[1].message_code, logs[1].information) == (7, 56, 123, "details")


@requires_trnrund
def test_poll_and_wait_return_every_change_once(start: StartDaemon, tmp_path: Path) -> None:
    """Hand out each saved change once, ending with the finished run and all its logs."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "model.dck"))
    runs: list[SimulationInfo] = []
    log_ids: list[int] = []
    deadline = time.monotonic() + TIMEOUT
    while not (runs and runs[-1].is_finished) and time.monotonic() < deadline:
        changes = daemon.wait(0.5)
        runs.extend(changes.runs)
        log_ids.extend(log.log_id for log in changes.logs)

    assert runs[-1].run_id == run_id
    assert runs[-1].is_finished
    assert [info.revision for info in runs] == sorted({info.revision for info in runs})
    assert log_ids == [1, 2, 3]
    assert not daemon.poll()


@requires_trnrund
def test_failed_run_is_reported(start: StartDaemon, tmp_path: Path) -> None:
    """Keep TRNRun's ERROR status and exit code for a failed run."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "failed.dck", FAILED_EVENTS, exit_code=1))

    info = wait_until(daemon, run_id, finished)

    assert not info.succeeded
    assert info.exit_code == 1
    assert info.status == StatusEvent(SimulationStatus.ERROR, "Fake failure")


@requires_trnrund
def test_run_without_terminal_status_is_an_error(start: StartDaemon, tmp_path: Path) -> None:
    """Give a run that exits without a terminal status a daemon-owned ERROR."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "silent.dck", []))

    info = wait_until(daemon, run_id, finished)

    assert not info.succeeded
    assert info.exit_code == 0
    assert info.status == StatusEvent(SimulationStatus.ERROR, "TRNRun exited without a terminal status")


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

    info = daemon.database.get_run(run_id)
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

    info = daemon.database.get_run(run_id)
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

    with pytest.raises(ValueError, match=message):
        _ = daemon.add(tmp_path / deck_name, args)

    assert daemon.database.get_runs() == []


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

    queued = daemon.database.get_run(queued_id)
    assert queued is not None
    assert queued.is_finished
    assert queued.started_at is None
    assert queued.status == StatusEvent(SimulationStatus.CANCELLED, "Not started")
    assert queued.error == "Not started: cancelled by the client"

    daemon.cancel(running_id)
    cancelled = wait_until(daemon, running_id, finished)

    assert cancelled.status == StatusEvent(SimulationStatus.CANCELLED, "Interrupted")
    assert cancelled.error == "Interrupted: cancelled by the client"
    assert not cancelled.succeeded


@requires_trnrund
def test_cancel_leaves_a_finished_run_unchanged(start: StartDaemon, tmp_path: Path) -> None:
    """Keep a finished run's real outcome."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "model.dck"))
    before = wait_until(daemon, run_id, finished)

    daemon.cancel(run_id)

    assert daemon.database.get_run(run_id) == before


@requires_trnrund
def test_cancel_unknown_run_is_rejected(start: StartDaemon) -> None:
    """Reject a run ID trnrund never assigned."""
    daemon = start()

    with pytest.raises(ValueError, match="999"):
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

    done = daemon.database.get_run(running_id)
    queued = daemon.database.get_run(queued_id)
    assert done is not None
    assert done.succeeded
    assert queued is not None
    assert queued.status == StatusEvent(SimulationStatus.CANCELLED, "Not started")
    assert queued.error == "Not started: the daemon shut down"
    assert daemon.exit_error() is None


@requires_trnrund
def test_shutdown_cancel_running_kills_running_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Kill running runs at once with ``cancel_running``."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "gate.dck", gated=True))
    _ = wait_until(daemon, run_id, running)

    daemon.shutdown(cancel_running=True, timeout=TIMEOUT)

    info = daemon.database.get_run(run_id)
    assert info is not None
    assert info.status == StatusEvent(SimulationStatus.CANCELLED, "Interrupted")


@requires_trnrund
def test_shutdown_timeout_interrupts_running_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Close stdin once the timeout passes, saving running runs as interrupted."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "gate.dck", gated=True))
    _ = wait_until(daemon, run_id, running)

    daemon.shutdown(timeout=0.2)

    info = daemon.database.get_run(run_id)
    assert info is not None
    assert info.is_finished
    assert info.error == "Interrupted: the client disconnected"


@requires_trnrund
def test_after_shutdown_reads_work_and_requests_fail(start: StartDaemon, tmp_path: Path) -> None:
    """Keep the database readable, stop blocking in wait(), and refuse new requests."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "model.dck"))
    daemon.shutdown(timeout=TIMEOUT)

    started = time.monotonic()
    changes = daemon.wait()

    assert time.monotonic() - started < 5.0
    assert [info.run_id for info in changes.runs] == [run_id]
    assert daemon.exit_error() is None
    with pytest.raises(RuntimeError, match="trnrund is closed"):
        _ = daemon.add(tmp_path / "model.dck")


# -----------------------------------------------------------------
# Following changes
# -----------------------------------------------------------------
@requires_trnrund
def test_wait_times_out_with_no_changes(start: StartDaemon) -> None:
    """Return an empty Changes when nothing is saved within the timeout."""
    daemon = start()

    assert not daemon.wait(0.1)
    assert daemon.wait_for_change(daemon.database.revision, 0.1) is False


@requires_trnrund
def test_wait_for_change_announces_saved_revisions(start: StartDaemon, tmp_path: Path) -> None:
    """Wake readers with their own database once a later revision is saved."""
    daemon = start()
    _ = daemon.add(write_deck(tmp_path / "model.dck"))

    assert daemon.wait_for_change(0, TIMEOUT) is True


@requires_trnrund
def test_crash_is_raised_after_its_changes(start: StartDaemon, tmp_path: Path) -> None:
    """Return what a crashed trnrund saved, then raise its exit instead of hanging."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "gate.dck", gated=True))
    _ = wait_until(daemon, run_id, running)
    daemon._process._popen.kill()

    with pytest.raises(RuntimeError, match="trnrund exited with code 1"):  # noqa: PT012 - drains first
        for _ in range(100):
            _ = daemon.wait(0.5)

    assert isinstance(daemon.exit_error(), RuntimeError)
