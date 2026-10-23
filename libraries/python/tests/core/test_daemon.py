"""Tests for ``trnrun.core.daemon``: driving the bundled trnrund and asking for its runs.

The daemon is real; TRNRun is Python running decks from ``helpers.write_deck``.
"""

import threading
import time
from collections.abc import Callable, Iterator
from pathlib import Path

import pytest

from tests.helpers import FAILED_EVENTS, FAKE_TRNRUND, PYTHON, release, requires_trnrund, write_deck
from trnrun.core import daemon as daemon_module
from trnrun.core._process import DaemonProcess
from trnrun.core.daemon import Daemon
from trnrun.core.errors import ClosedError, DaemonExitedError, ProtocolVersionError, RequestRejectedError
from trnrun.core.records import SimulationInfo, SimulationState, SimulationStatus
from trnrun.core.settings import SimulationSettings

type StartDaemon = Callable[..., Daemon]

TIMEOUT = 30.0  # Seconds any run gets to reach the state a test waits for.


@pytest.fixture
def start() -> Iterator[StartDaemon]:
    """Return a function starting a daemon on the fake TRNRun; every one started is closed afterwards."""
    started: list[Daemon] = []

    def start(**kwargs: object) -> Daemon:
        """Start a daemon, by default with two slots."""
        kwargs.setdefault("trnrun_path", PYTHON)
        kwargs.setdefault("max_concurrent", 2)
        daemon = Daemon(**kwargs)  # ty: ignore[invalid-argument-type]  # pyright: ignore[reportArgumentType]
        started.append(daemon)
        return daemon

    yield start
    for daemon in started:
        daemon.close()


def wait_until(daemon: Daemon, run_id: int, done: Callable[[SimulationInfo], bool]) -> SimulationInfo:
    """Poll run ``run_id`` until it satisfies ``done``, and return it."""
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        info = daemon.get(run_id)
        if done(info):
            return info
        time.sleep(0.01)
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
        _ = Daemon(trnrund_path=tmp_path / "trnrund.exe")


def test_another_protocol_version_is_refused(monkeypatch: pytest.MonkeyPatch) -> None:
    """Raise ProtocolVersionError, a ValueError, for a trnrund speaking another protocol, and stop it."""
    started: list[DaemonProcess] = []

    def fake(_path: object, args: list[str]) -> DaemonProcess:
        """Start the fake trnrund, which reports protocol 3."""
        started.append(DaemonProcess(PYTHON, ["-I", str(FAKE_TRNRUND), "--protocol:3", *args]))
        return started[-1]

    monkeypatch.setattr(daemon_module, "DaemonProcess", fake)

    with pytest.raises(ProtocolVersionError, match="trnrund speaks protocol 3; this package needs 2") as raised:
        _ = Daemon()
    assert isinstance(raised.value, ValueError)
    assert started[0]._popen.returncode == 0  # Closed, not left running.


@requires_trnrund
def test_no_thread_is_started(start: StartDaemon, tmp_path: Path) -> None:
    """Run every request on the caller's thread."""
    before = threading.active_count()

    daemon = start()
    run = daemon.add(write_deck(tmp_path / "model.dck"), wait_for="FINISHED")
    _ = daemon.get(run.run_id)

    assert threading.active_count() == before


@requires_trnrund
def test_closing_stops_trnrund(start: StartDaemon, tmp_path: Path) -> None:
    """Refuse every request once the with block closed the daemon, even with a run unfinished."""
    with start() as daemon:
        run = daemon.add(write_deck(tmp_path / "gate.dck", gated=True), wait_for="RUNNING")
        assert run.state is SimulationState.RUNNING

    with pytest.raises(ClosedError, match="trnrund is closed"):
        _ = daemon.get(run.run_id)
    daemon.close()  # Safe more than once.


# -----------------------------------------------------------------
# Adding runs
# -----------------------------------------------------------------
@requires_trnrund
def test_added_run_is_followed_to_success(start: StartDaemon, tmp_path: Path) -> None:
    """Report a run's events, logs and outcome as trnrund replies with them."""
    daemon = start()
    added = daemon.add(write_deck(tmp_path / "model.dck"), ["--pollMs:10"], label="baseline")

    info = wait_until(daemon, added.run_id, finished)

    assert info.succeeded is True
    assert (info.exit_code, info.error) == (0, None)
    assert info.label == "baseline"
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
    logs = info.logs
    assert [(log.severity, log.message) for log in logs] == [
        ("Notice", "first"),
        ("Warning", "second"),
        ("Fatal", "third"),
    ]
    assert (logs[1].unit_id, logs[1].type_id, logs[1].message_code, logs[1].information) == (7, 56, 123, "details")


@requires_trnrund
def test_add_waits_for_the_given_state(start: StartDaemon, tmp_path: Path) -> None:
    """Return the run at once for QUEUED, once started for RUNNING, and its outcome for FINISHED."""
    daemon = start(max_concurrent=1)
    gate = write_deck(tmp_path / "gate.dck", gated=True)

    running_run = daemon.add(gate, wait_for=SimulationState.RUNNING)
    queued = daemon.add(write_deck(tmp_path / "queued.dck"))
    release(gate)
    done = daemon.add(write_deck(tmp_path / "done.dck"), wait_for="FINISHED")

    assert running_run.state is SimulationState.RUNNING
    assert queued.state is SimulationState.QUEUED
    assert done.succeeded is True
    assert done.run_id == queued.run_id + 1
    with pytest.raises(ValueError, match="STARTED"):
        _ = daemon.add(gate, wait_for="STARTED")  # ty: ignore[invalid-argument-type]  # pyright: ignore[reportArgumentType]


@requires_trnrund
def test_each_run_holds_only_its_own_logs(start: StartDaemon, tmp_path: Path) -> None:
    """Return every log entry of a run with it, and none of another run's."""
    daemon = start(max_concurrent=1)
    first = daemon.add(write_deck(tmp_path / "first.dck"), wait_for="FINISHED")
    second = daemon.add(write_deck(tmp_path / "second.dck"), wait_for="FINISHED")

    assert [log.message for log in first.logs] == ["first", "second", "third"]
    assert daemon.get(first.run_id) == first
    assert daemon.get(second.run_id).logs == first.logs


@requires_trnrund
def test_failed_run_is_reported(start: StartDaemon, tmp_path: Path) -> None:
    """Keep TRNRun's ERROR status and exit code for a failed run."""
    daemon = start()

    info = daemon.add(write_deck(tmp_path / "failed.dck", FAILED_EVENTS, exit_code=1), wait_for="FINISHED")

    assert info.succeeded is False
    assert info.exit_code == 1
    assert (info.status, info.status_message) == (SimulationStatus.ERROR, "Fake failure")


@requires_trnrund
def test_run_without_terminal_status_is_an_error(start: StartDaemon, tmp_path: Path) -> None:
    """Give a run that exits without a terminal status a daemon-owned ERROR."""
    daemon = start()

    info = daemon.add(write_deck(tmp_path / "silent.dck", []), wait_for="FINISHED")

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

    assert daemon.add("model.dck").deck_file == tmp_path / "model.dck"


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

    assert daemon.add(write_deck(tmp_path / "model.dck"), settings).trnrun_args == settings.to_cli_args()


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

    with pytest.raises(RequestRejectedError, match="Unknown runId"):
        _ = daemon.get(1)


# -----------------------------------------------------------------
# Releasing and cancelling
# -----------------------------------------------------------------
@requires_trnrund
def test_release_deletes_finished_runs_only(start: StartDaemon, tmp_path: Path) -> None:
    """Delete a finished run, refuse an unfinished one, and skip unknown IDs."""
    daemon = start()
    done = daemon.add(write_deck(tmp_path / "model.dck"), wait_for="FINISHED")
    gate = daemon.add(write_deck(tmp_path / "gate.dck", gated=True))

    with pytest.raises(RequestRejectedError, match=f"Run {gate.run_id} is not FINISHED"):
        daemon.release(gate.run_id)
    daemon.release(done.run_id)
    daemon.release(done.run_id)
    daemon.release(99)

    with pytest.raises(RequestRejectedError, match="Unknown runId"):
        _ = daemon.get(done.run_id)


@requires_trnrund
def test_cancel_queued_and_running_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Finish a queued run on return, and a running one once it is killed."""
    daemon = start(max_concurrent=1)
    running_id = daemon.add(write_deck(tmp_path / "gate.dck", gated=True), wait_for="RUNNING").run_id
    queued_id = daemon.add(write_deck(tmp_path / "model.dck")).run_id

    daemon.cancel(queued_id)

    queued = daemon.get(queued_id)
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
    before = daemon.add(write_deck(tmp_path / "model.dck"), wait_for="FINISHED")

    daemon.cancel(before.run_id)

    assert daemon.get(before.run_id) == before


@requires_trnrund
def test_cancel_unknown_run_is_rejected(start: StartDaemon) -> None:
    """Reject a run ID trnrund never assigned."""
    daemon = start()

    with pytest.raises(RequestRejectedError, match="999"):
        daemon.cancel(999)


# -----------------------------------------------------------------
# Shutting down and failures
# -----------------------------------------------------------------
@requires_trnrund
def test_shutdown_cancels_queued_runs_and_keeps_answering(start: StartDaemon, tmp_path: Path) -> None:
    """Let a running run finish, never start a queued one, refuse new runs, and answer until closed."""
    daemon = start(max_concurrent=1)
    gate = write_deck(tmp_path / "gate.dck", gated=True)
    running_id = daemon.add(gate, wait_for="RUNNING").run_id
    queued_id = daemon.add(write_deck(tmp_path / "model.dck")).run_id

    daemon.shutdown()
    release(gate)

    done = wait_until(daemon, running_id, finished)
    queued = daemon.get(queued_id)
    assert done.succeeded is True
    assert (queued.status, queued.status_message) == (SimulationStatus.CANCELLED, "Not started")
    assert queued.error == "Not started: the daemon shut down"
    with pytest.raises(RequestRejectedError, match="shutting down"):
        _ = daemon.add(gate)


@requires_trnrund
def test_shutdown_cancel_running_kills_running_runs(start: StartDaemon, tmp_path: Path) -> None:
    """Kill running runs at once with ``cancel_running``."""
    daemon = start()
    run_id = daemon.add(write_deck(tmp_path / "gate.dck", gated=True), wait_for="RUNNING").run_id

    daemon.shutdown(cancel_running=True)

    info = wait_until(daemon, run_id, finished)
    assert (info.status, info.status_message) == (SimulationStatus.CANCELLED, "Interrupted")
    assert info.error == "Interrupted: the daemon shut down"


@requires_trnrund
def test_crash_is_raised_by_the_next_request(start: StartDaemon, tmp_path: Path) -> None:
    """Raise a killed trnrund's exit instead of hanging."""
    daemon = start()
    _ = daemon.add(write_deck(tmp_path / "gate.dck", gated=True), wait_for="RUNNING")

    daemon._process._popen.kill()

    with pytest.raises(DaemonExitedError, match="trnrund exited with code 1") as raised:
        _ = daemon.get(1)
    assert raised.value.exit_code == 1
