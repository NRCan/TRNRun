"""Tests for ``trnrun.manager``: handles kept in sync with a trnrund daemon.

The daemon is real; TRNRun is Python running decks from ``helpers.write_deck``.
"""

import threading
import time
from collections.abc import Callable, Iterator, Sequence
from pathlib import Path

import pytest

from tests.helpers import DONE_EVENTS, FAILED_EVENTS, PYTHON, release, requires_trnrund, write_deck
from trnrun.core.errors import ClosedError, DaemonExitedError, RequestRejectedError
from trnrun.core.records import SimulationState, SimulationStatus
from trnrun.core.settings import SimulationSettings
from trnrun.manager import SimulationManager
from trnrun.simulation import Simulation

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

    def start(**kwargs: object) -> SimulationManager:
        """Start a manager, by default without a display, refreshing every 10 ms."""
        kwargs.setdefault("trnrun_path", PYTHON)
        kwargs.setdefault("max_concurrent", 2)
        kwargs.setdefault("refresh_interval", 0.01)
        kwargs.setdefault("display", False)
        manager = SimulationManager(**kwargs)  # ty: ignore[invalid-argument-type]  # pyright: ignore[reportArgumentType]
        started.append(manager)
        return manager

    yield start
    for manager in started:
        manager.shutdown()


def refresh_until(manager: SimulationManager, simulation: Simulation, state: SimulationState) -> None:
    """Refresh until the handle reaches ``state``."""
    deadline = time.monotonic() + TIMEOUT
    while simulation.state is not state:
        if time.monotonic() > deadline:
            raise AssertionError(f"{simulation!r} did not reach {state} within {TIMEOUT} s")
        manager.refresh()
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
def test_no_thread_is_started(start: StartManager, tmp_path: Path) -> None:
    """Sync only on the caller's thread."""
    before = threading.active_count()

    manager = start()
    _ = manager.add(write_deck(tmp_path / "done.dck"))
    manager.wait(timeout=TIMEOUT)

    assert threading.active_count() == before


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
    assert (done.notices, done.warnings, done.fatals) == (1, 1, 1)
    assert [log.message for log in done.logs] == ["first", "second", "third"]
    assert failed.is_finished
    assert failed.succeeded is False
    assert failed.status is SimulationStatus.ERROR
    assert failed.info.status_message == "Fake failure"
    assert failed.info.exit_code == 1
    assert manager.active == []


@requires_trnrund
def test_finished_runs_are_released_once_their_logs_are_in(
    start: StartManager,
    tmp_path: Path,
) -> None:
    """Collect every log entry once, then release the finished runs from the daemon."""
    many: list[dict[str, object]] = [
        {"kind": "LOG", "severity": "Notice", "time": index, "message": str(index)} for index in range(7)
    ]
    manager = start()
    first = manager.add(write_deck(tmp_path / "first.dck", [*many, *DONE_EVENTS]))
    second = manager.add(write_deck(tmp_path / "second.dck", [*many, *DONE_EVENTS]))

    manager.wait(timeout=TIMEOUT)

    for simulation in (first, second):
        assert [log.message for log in simulation.logs] == [*map(str, range(7)), "first", "second", "third"]
        with pytest.raises(RequestRejectedError, match="Unknown runId"):
            _ = manager._daemon.get(simulation.run_id)


@requires_trnrund
def test_refresh_updates_the_handles(start: StartManager, tmp_path: Path) -> None:
    """Change a handle only when refreshed."""
    manager = start(max_concurrent=1)
    gate = write_deck(tmp_path / "gate.dck", gated=True)
    first = manager.add(gate)
    second = manager.add(write_deck(tmp_path / "done.dck"))

    refresh_until(manager, first, SimulationState.RUNNING)
    release(gate)
    time.sleep(0.5)

    assert second.state is SimulationState.QUEUED  # Not refreshed since.
    manager.wait(timeout=TIMEOUT)
    assert (first.succeeded, second.succeeded) == (True, True)


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
    refresh_until(manager, first, SimulationState.RUNNING)

    assert manager.active == [first, second]
    assert second.state is SimulationState.QUEUED

    release(gate)
    manager.wait(timeout=TIMEOUT)
    assert manager.active == []


@requires_trnrund
def test_add_waits_for_the_given_state(start: StartManager, tmp_path: Path) -> None:
    """Return the handle only once it reaches wait_for, given as a state or its name, at once for QUEUED."""
    manager = start(max_concurrent=1)
    gate = write_deck(tmp_path / "gate.dck", gated=True)

    running = manager.add(gate, wait_for=SimulationState.RUNNING)
    queued = manager.add(write_deck(tmp_path / "queued.dck"))

    assert running.state is SimulationState.RUNNING
    assert queued.state is SimulationState.QUEUED
    release(gate)
    finished = manager.add(write_deck(tmp_path / "done.dck"), wait_for="FINISHED")

    assert finished.succeeded
    assert finished not in manager.active
    assert queued.is_finished


@requires_trnrund
def test_add_rejects_an_unknown_wait_for(start: StartManager, tmp_path: Path) -> None:
    """Raise ValueError for a wait_for that is not a state name, without queueing the run."""
    manager = start()

    with pytest.raises(ValueError, match="STARTED"):
        _ = manager.add(write_deck(tmp_path / "done.dck"), wait_for="STARTED")  # ty: ignore[invalid-argument-type]  # pyright: ignore[reportArgumentType]

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
def test_display_gets_every_change_before_wait_returns_and_is_closed(start: StartManager, tmp_path: Path) -> None:
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
    running = manager.add(write_deck(tmp_path / "gate.dck", gated=True), wait_for="RUNNING")
    queued = manager.add(write_deck(tmp_path / "done.dck"))

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
def test_shutdown_collects_the_last_results(start: StartManager, tmp_path: Path) -> None:
    """Finish unfinished handles as CANCELLED, keep finished ones, and refuse new work."""
    manager = start(max_concurrent=1)
    done = manager.add(write_deck(tmp_path / "done.dck"), wait_for="FINISHED")
    gate = manager.add(write_deck(tmp_path / "gate.dck", gated=True), wait_for="RUNNING")
    queued = manager.add(write_deck(tmp_path / "queued.dck"))

    manager.shutdown()
    manager.shutdown()  # Later calls do nothing.

    assert done.succeeded
    assert (gate.status, gate.error) == (SimulationStatus.CANCELLED, "Interrupted: the daemon shut down")
    assert (queued.status, queued.error) == (SimulationStatus.CANCELLED, "Not started: the daemon shut down")
    manager.wait()  # Every run finished: returns at once.
    with pytest.raises(ClosedError, match="SimulationManager is closed"):
        _ = manager.add(tmp_path / "done.dck")
    with pytest.raises(ClosedError, match="SimulationManager is closed"):
        manager.refresh()
    with pytest.raises(ClosedError, match="SimulationManager is closed"), manager:
        pass


@requires_trnrund
def test_daemon_crash_is_raised_instead_of_hanging(start: StartManager, tmp_path: Path) -> None:
    """Raise the daemon's exit for unfinished runs and later calls."""
    manager = start()
    simulation = manager.add(write_deck(tmp_path / "gate.dck", gated=True), wait_for="RUNNING")

    manager._daemon._process._popen.kill()
    with pytest.raises(DaemonExitedError, match="trnrund exited with code 1") as raised:
        manager.wait(timeout=TIMEOUT)
    assert raised.value.exit_code == 1

    with pytest.raises(DaemonExitedError, match="code 1"):
        _ = manager.add(tmp_path / "gate.dck")
    assert simulation.state is SimulationState.RUNNING  # Handles keep their last state.
    manager.shutdown()  # Still releases everything.


@requires_trnrund
def test_shutdown_returns_promptly(start: StartManager, tmp_path: Path) -> None:
    """Kill running runs rather than wait for them."""
    manager = start()
    _ = manager.add(write_deck(tmp_path / "gate.dck", gated=True), wait_for="RUNNING")

    started = time.monotonic()
    manager.shutdown()

    assert time.monotonic() - started < 5.0
