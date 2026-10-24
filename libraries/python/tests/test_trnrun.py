"""Daemon and SimulationManager against the real trnrund.exe, with Python as the runner."""

import time
from collections.abc import Callable
from pathlib import Path

import pytest

from tests.conftest import PYTHON
from trnrun import (
    Daemon,
    DaemonExitedError,
    LogEvent,
    LogSeverity,
    RequestError,
    SimulationManager,
    SimulationState,
    SimulationStatus,
)

type DeckWriter = Callable[..., Path]


def test_daemon_runs_a_deck_to_the_end(deck: DeckWriter) -> None:
    """add, get, list and release follow one simulation from queued to forgotten."""
    with Daemon(workers=1, trnrun_path=PYTHON) as daemon:
        sim_id = daemon.add(deck(), label="one")
        while not daemon.get(sim_id).is_finished:
            time.sleep(0.01)
        [sim] = daemon.list(SimulationState.FINISHED, with_logs=True)
        assert (sim.sim_id, sim.label, sim.succeeded, sim.warnings) == (sim_id, "one", True, 1)
        assert sim.status is SimulationStatus.DONE
        assert (sim.start_time, sim.stop_time, sim.time_step) == (0, 10, 1)
        assert (sim.sim_time, sim.percent, sim.elapsed_ms, sim.eta_ms) == (10, 1, 5, 0)
        assert sim.logs == [LogEvent(LogSeverity.WARNING, 5, unit_id=7, type_id=56, message="careful")]
        assert sim.submitted_at is not None
        assert sim.finished_at is not None
        assert sim.submitted_at <= sim.finished_at
        assert daemon.list("FINISHED")[0].logs == []  # Without with_logs.
        daemon.release(sim_id)
        assert daemon.list("FINISHED") == []


def test_daemon_errors(tmp_path: Path) -> None:
    """A refused request raises RequestError; a closed daemon raises DaemonExitedError."""
    daemon = Daemon(trnrun_path=PYTHON)
    with pytest.raises(RequestError, match="Deck file not found"):
        _ = daemon.add(tmp_path / "missing.dck")
    with pytest.raises(RequestError, match="Unknown simId"):
        _ = daemon.get(99)
    daemon.close()
    daemon.close()
    with pytest.raises(DaemonExitedError, match="code 0"):
        _ = daemon.get(1)


def test_manager_wait_for_running_blocks_until_started(deck: DeckWriter) -> None:
    """With one worker, the second deck stays queued until the first finishes."""
    with SimulationManager(workers=1, display=False, poll_interval=0.01, trnrun_path=PYTHON) as manager:
        first_deck = deck(gated=True)
        first = manager.add(first_deck, wait_for="RUNNING")
        assert first.state == "RUNNING"
        second = manager.add(deck())
        manager.refresh()
        assert second.state == "QUEUED"
        first_deck.with_suffix(".go").touch()
        manager.wait(second, until="RUNNING")
        manager.wait()
        assert [sim.succeeded for sim in manager.simulations.values()] == [True, True]
        assert second.logs[0].message == "careful"  # The returned Simulation was updated in place.


def test_manager_wait_for_finished_and_display(deck: DeckWriter, capsys: pytest.CaptureFixture[str]) -> None:
    """wait_for FINISHED returns the outcome; the display prints each finished run once."""
    with SimulationManager(workers=2, poll_interval=0.01, trnrun_path=PYTHON) as manager:
        sims = [manager.add(deck(), label=f"run{i}", wait_for="FINISHED") for i in range(3)]
        assert all(sim.succeeded and sim.is_finished for sim in sims)
        assert repr(sims[0]) == "Simulation(sim_id=1, deck='deck1.dck', state=FINISHED, status=DONE, 100%)"
    out = capsys.readouterr().out
    assert [out.count(f"run{i}") for i in range(3)] == [1, 1, 1]
    assert "DONE" in out


def test_manager_rejects_bad_wait_for_before_queuing(deck: DeckWriter) -> None:
    """A wrong wait_for raises ValueError and queues nothing."""
    with SimulationManager(display=False, trnrun_path=PYTHON) as manager:
        with pytest.raises(ValueError, match="not a valid SimulationState"):
            _ = manager.add(deck(), wait_for="DONE")  # pyright: ignore[reportArgumentType]
        assert manager.daemon.list("QUEUED") == []
        assert manager.simulations == {}


def test_manager_wait_timeout(deck: DeckWriter) -> None:
    """Wait raises TimeoutError while a simulation is still running."""
    with SimulationManager(display=False, poll_interval=0.01, trnrun_path=PYTHON) as manager:
        sim = manager.add(deck(gated=True))
        with pytest.raises(TimeoutError):
            manager.wait(sim, timeout=0.2)
