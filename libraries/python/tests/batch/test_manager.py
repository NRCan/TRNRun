"""Tests for ``trnrun.batch.manager``: handles kept in sync with a trnrund daemon.

The daemon is real; TRNRun is Python running decks from ``helpers.write_deck``.
"""

import sqlite3
import time
from collections.abc import Callable, Iterator, Sequence
from contextlib import closing
from pathlib import Path

import pytest

from tests.helpers import FAILED_EVENTS, PYTHON, release, requires_trnrund, write_deck
from trnrun.batch import manager as manager_module
from trnrun.batch.manager import SimulationManager
from trnrun.batch.simulation import Simulation
from trnrun.database import connect
from trnrun.errors import ClosedError, DaemonExitedError, RequestRejectedError, SyncError
from trnrun.events import SimulationStatus
from trnrun.runs import SimulationState, parse_run
from trnrun.settings import SimulationSettings

type StartManager = Callable[..., SimulationManager]

TIMEOUT = 30.0  # Seconds any run gets to reach the state a test waits for.


class RecordingDisplay:
    """A ``Display`` that records each update as (run ID, state) pairs."""

    def __init__(self) -> None:
        """Start with no updates."""
        self.updates: list[list[tuple[int, SimulationState]]] = []
        self.closed: int = 0

    def update(self, changed: Sequence[Simulation]) -> None:
        """Record the runs that changed."""
        self.updates.append([(simulation.run_id, simulation.state) for simulation in changed])

    def close(self) -> None:
        """Count the closes."""
        self.closed += 1


class FailingDisplay(RecordingDisplay):
    """A ``Display`` whose updates always fail."""

    def update(self, changed: Sequence[Simulation]) -> None:
        """Fail after recording."""
        super().update(changed)
        raise RuntimeError("display broke")


@pytest.fixture
def start() -> Iterator[StartManager]:
    """Return a function starting a manager on the fake TRNRun; every one started is shut down afterwards."""
    started: list[SimulationManager] = []

    def start(database_path: str | Path | None = None, **kwargs: object) -> SimulationManager:
        """Start a manager, by default without a display, syncing every 10 ms."""
        kwargs.setdefault("trnrun_path", PYTHON)
        kwargs.setdefault("max_concurrent", 2)
        kwargs.setdefault("refresh_interval", 0.01)
        kwargs.setdefault("display", False)
        manager = SimulationManager(database_path, **kwargs)  # ty: ignore[invalid-argument-type]  # pyright: ignore[reportArgumentType]
        started.append(manager)
        return manager

    yield start
    for manager in started:
        manager.shutdown()


def wait_for_state(simulation: Simulation, state: SimulationState) -> None:
    """Block until the handle reaches ``state``."""
    deadline = time.monotonic() + TIMEOUT
    while simulation.state is not state:
        if time.monotonic() > deadline:
            raise AssertionError(f"{simulation!r} did not reach {state} within {TIMEOUT} s")
        time.sleep(0.01)


# -----------------------------------------------------------------
# Starting
# -----------------------------------------------------------------
def test_negative_refresh_interval_is_rejected() -> None:
    """Refuse a negative interval before starting anything."""
    with pytest.raises(ValueError, match="refresh_interval must not be negative"):
        _ = SimulationManager(refresh_interval=-1.0)


def test_startup_failure_closes_the_display(tmp_path: Path) -> None:
    """Release the display when the daemon cannot start."""
    display = RecordingDisplay()

    with pytest.raises(FileNotFoundError):
        _ = SimulationManager(trnrund_path=tmp_path / "trnrund.exe", display=display)

    assert display.closed == 1


@requires_trnrund
def test_temporary_database_is_deleted_on_shutdown(start: StartManager) -> None:
    """Keep the runs in a temporary database, deleted by shutdown."""
    manager = start()
    path = manager.database_path

    assert path.is_file()
    assert manager.session_id == 1
    manager.shutdown()

    assert not path.parent.exists()


@requires_trnrund
def test_given_database_outlives_the_manager(start: StartManager, tmp_path: Path) -> None:
    """Keep a given database, with the manager's runs, after shutdown."""
    path = tmp_path / "runs.sqlite3"
    with start(path) as manager:
        simulation = manager.add(write_deck(tmp_path / "model.dck"))
        manager.wait(timeout=TIMEOUT)

    with closing(connect(path)) as connection:
        row = connection.execute("SELECT * FROM runs WHERE run_id = ?", (simulation.run_id,)).fetchone()

    assert parse_run(row).succeeded is True


# -----------------------------------------------------------------
# Adding and waiting
# -----------------------------------------------------------------
@requires_trnrund
def test_added_runs_are_synced_until_finished(start: StartManager, tmp_path: Path) -> None:
    """Keep each handle in sync, with its logs, until it finishes."""
    manager = start()
    done = manager.add(write_deck(tmp_path / "done.dck"), label="baseline")
    failed = manager.add(write_deck(tmp_path / "failed.dck", FAILED_EVENTS, exit_code=1))

    manager.wait(timeout=TIMEOUT)

    assert done.is_finished
    assert done.succeeded is True
    assert done.status is SimulationStatus.DONE
    assert done.info.label == "baseline"
    assert done.info.session_id == manager.session_id
    assert (done.notices, done.warnings, done.fatals) == (1, 1, 1)
    assert [log.message for log in done.logs] == ["first", "second", "third"]
    assert failed.is_finished
    assert failed.succeeded is False
    assert failed.status is SimulationStatus.ERROR
    assert failed.info.status_message == "Fake failure"
    assert failed.info.exit_code == 1
    assert manager.active == []


@requires_trnrund
def test_wait_for_one_simulation(start: StartManager, tmp_path: Path) -> None:
    """Return once that run finished, while others still run."""
    manager = start()
    gate = manager.add(write_deck(tmp_path / "gate.dck", gated=True))
    done = manager.add(write_deck(tmp_path / "done.dck"))

    manager.wait(done, timeout=TIMEOUT)

    assert done.is_finished
    assert not gate.is_finished
    assert manager.active == [gate]


@requires_trnrund
def test_wait_times_out(start: StartManager, tmp_path: Path) -> None:
    """Raise TimeoutError for runs still unfinished after the timeout."""
    manager = start()
    gate = write_deck(tmp_path / "gate.dck", gated=True)
    simulation = manager.add(gate)

    with pytest.raises(TimeoutError):
        manager.wait(timeout=0.1)

    release(gate)
    manager.wait(simulation, timeout=TIMEOUT)
    assert simulation.succeeded


@requires_trnrund
def test_active_lists_unfinished_runs_in_submission_order(start: StartManager, tmp_path: Path) -> None:
    """List queued and running runs, but not finished ones."""
    manager = start(max_concurrent=1)
    gate = write_deck(tmp_path / "gate.dck", gated=True)
    first = manager.add(gate)
    second = manager.add(write_deck(tmp_path / "done.dck"))
    wait_for_state(first, SimulationState.RUNNING)

    assert manager.active == [first, second]
    assert second.state is SimulationState.QUEUED

    release(gate)
    manager.wait(timeout=TIMEOUT)
    assert manager.active == []


@requires_trnrund
def test_add_copies_the_settings(start: StartManager, tmp_path: Path) -> None:
    """Let callers change and reuse settings after submitting them."""
    manager = start()
    settings = SimulationSettings(poll_ms=10)

    simulation = manager.add(write_deck(tmp_path / "done.dck"), settings)
    settings.poll_ms = 20

    assert simulation.settings is not settings
    assert simulation.settings.poll_ms == 10
    manager.wait(simulation, timeout=TIMEOUT)
    assert simulation.info.trnrun_args == ["--pollMs:10"]


@requires_trnrund
def test_relative_deck_resolves_from_the_working_directory(
    start: StartManager,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Record the deck as an absolute path."""
    _ = write_deck(tmp_path / "done.dck")
    monkeypatch.chdir(tmp_path)
    manager = start()

    simulation = manager.add("done.dck")

    assert simulation.deck_file == tmp_path / "done.dck"


@requires_trnrund
def test_add_rejects_invalid_runs(start: StartManager, tmp_path: Path) -> None:
    """Raise for a missing TRNSYS or a deck the daemon rejects, without tracking it."""
    manager = start()

    with pytest.raises(FileNotFoundError):
        _ = manager.add(write_deck(tmp_path / "done.dck"), SimulationSettings(trnexe_path=tmp_path / "missing.exe"))
    with pytest.raises(RequestRejectedError, match="Deck file not found"):
        _ = manager.add(tmp_path / "missing.dck")

    assert manager.active == []


# -----------------------------------------------------------------
# Display
# -----------------------------------------------------------------
@requires_trnrund
def test_display_gets_every_change_and_is_closed(start: StartManager, tmp_path: Path) -> None:
    """Show changed runs in submission order, including their final state, then close the display."""
    display = RecordingDisplay()
    manager = start(display=display)
    first = manager.add(write_deck(tmp_path / "first.dck"))
    second = manager.add(write_deck(tmp_path / "second.dck"))

    manager.wait(timeout=TIMEOUT)

    assert all(update == sorted(update) for update in display.updates)
    shown = [entry for update in display.updates for entry in update]
    assert (first.run_id, SimulationState.FINISHED) in shown
    assert (second.run_id, SimulationState.FINISHED) in shown
    manager.shutdown()
    assert display.closed == 1


@requires_trnrund
def test_display_failure_never_stops_syncing(start: StartManager, tmp_path: Path) -> None:
    """Ignore a failing display update and keep syncing the runs."""
    display = FailingDisplay()
    manager = start(display=display)

    simulation = manager.add(write_deck(tmp_path / "done.dck"))
    manager.wait(timeout=TIMEOUT)

    assert simulation.succeeded
    assert display.updates


# -----------------------------------------------------------------
# Cancelling
# -----------------------------------------------------------------
@requires_trnrund
def test_cancel_queued_and_running_simulations(start: StartManager, tmp_path: Path) -> None:
    """Finish both as CANCELLED, keeping whether they started."""
    manager = start(max_concurrent=1)
    running = manager.add(write_deck(tmp_path / "gate.dck", gated=True))
    queued = manager.add(write_deck(tmp_path / "done.dck"))
    wait_for_state(running, SimulationState.RUNNING)

    manager.cancel(queued)
    manager.wait(queued, timeout=TIMEOUT)
    manager.cancel(running)
    manager.wait(running, timeout=TIMEOUT)

    assert queued.status is SimulationStatus.CANCELLED
    assert queued.error == "Not started: cancelled by the client"
    assert running.status is SimulationStatus.CANCELLED
    assert running.error == "Interrupted: cancelled by the client"
    assert running.succeeded is False


@requires_trnrund
def test_cancel_keeps_a_finished_outcome(start: StartManager, tmp_path: Path) -> None:
    """Leave a finished simulation's real outcome."""
    manager = start()
    simulation = manager.add(write_deck(tmp_path / "done.dck"))
    manager.wait(simulation, timeout=TIMEOUT)

    manager.cancel(simulation)

    assert simulation.succeeded
    assert simulation.status is SimulationStatus.DONE


@requires_trnrund
def test_foreign_simulation_is_rejected(start: StartManager, tmp_path: Path) -> None:
    """Refuse to cancel or wait for an unfinished simulation another manager added."""
    manager = start()
    stranger = Simulation(1, tmp_path / "done.dck", SimulationSettings())

    with pytest.raises(ValueError, match="was not added to this manager"):
        manager.cancel(stranger)
    with pytest.raises(ValueError, match="was not added to this manager"):
        manager.wait(stranger, timeout=0.1)


# -----------------------------------------------------------------
# Shutting down and failures
# -----------------------------------------------------------------
@requires_trnrund
def test_after_shutdown(start: StartManager, tmp_path: Path) -> None:
    """Keep finished handles, refuse new work, and raise for unfinished runs."""
    manager = start()
    done = manager.add(write_deck(tmp_path / "done.dck"))
    manager.wait(done, timeout=TIMEOUT)
    gate = manager.add(write_deck(tmp_path / "gate.dck", gated=True))
    wait_for_state(gate, SimulationState.RUNNING)

    manager.shutdown()
    manager.shutdown()  # Later calls do nothing.

    manager.wait(done)  # Already finished: returns at once.
    assert done.succeeded
    assert gate.state is SimulationState.RUNNING  # Handles keep their last state.
    with pytest.raises(ClosedError, match="SimulationManager is closed"):
        manager.wait(gate)
    with pytest.raises(ClosedError, match="SimulationManager is closed"):
        _ = manager.add(tmp_path / "done.dck")
    with pytest.raises(ClosedError, match="SimulationManager is closed"):
        manager.cancel(gate)
    with pytest.raises(ClosedError, match="SimulationManager is closed"), manager:
        pass


@requires_trnrund
def test_daemon_crash_stops_syncing(start: StartManager, tmp_path: Path) -> None:
    """Raise the daemon's exit for unfinished runs and later calls instead of hanging."""
    manager = start()
    simulation = manager.add(write_deck(tmp_path / "gate.dck", gated=True))
    wait_for_state(simulation, SimulationState.RUNNING)

    manager._daemon._process._popen.kill()
    with pytest.raises(DaemonExitedError, match="trnrund exited with code 1") as raised:
        manager.wait(timeout=TIMEOUT)
    assert raised.value.exit_code == 1

    with pytest.raises(DaemonExitedError, match="code 1"):
        _ = manager.add(tmp_path / "gate.dck")


@requires_trnrund
def test_database_failure_stops_syncing(
    start: StartManager,
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Raise SyncError, chaining the cause, when reading the database fails."""

    def broken(*_args: object) -> None:
        """Fail like an unreadable database."""
        raise sqlite3.OperationalError("disk I/O error")

    monkeypatch.setattr(manager_module, "read_changes", broken)
    manager = start()
    _ = manager.add(write_deck(tmp_path / "done.dck"))

    with pytest.raises(SyncError, match="stopped syncing: disk I/O error") as raised:
        manager.wait(timeout=TIMEOUT)
    assert isinstance(raised.value.__cause__, sqlite3.OperationalError)


@requires_trnrund
def test_shutdown_returns_promptly(start: StartManager) -> None:
    """Stop the background thread quickly, even though it now stops before the daemon."""
    manager = start()

    started = time.monotonic()
    manager.shutdown()

    assert time.monotonic() - started < 5.0
