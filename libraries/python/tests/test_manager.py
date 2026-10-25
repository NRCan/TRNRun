"""SimulationManager against the real trnrund.exe, with Python as the runner."""

import pytest

from tests.conftest import PYTHON, DeckWriter, requires_trnrund
from trnrun import SimulationManager, SimulationStatus

pytestmark = requires_trnrund


def _manager(workers: int = 1, *, display: bool = False) -> SimulationManager:
    """Return a manager polling every 10 ms, with Python as the runner."""
    return SimulationManager(workers=workers, display=display, poll_interval=0.01, trnrun_path=PYTHON)


def test_manager_wait_for_running_blocks_until_started(deck: DeckWriter) -> None:
    """With one worker, the second deck stays queued until the first finishes."""
    with _manager() as manager:
        first_deck = deck(gated=True)
        first = manager.add(first_deck, wait_for="RUNNING")
        assert first.state == "RUNNING"
        second = manager.add(deck(), wait_for="QUEUED")
        manager.refresh()
        assert second.state == "QUEUED"
        first_deck.with_suffix(".go").touch()
        manager.wait(second, until="RUNNING")
        manager.wait()
        assert [sim.succeeded for sim in manager.simulations.values()] == [True, True]
        assert second.logs[0].message == "careful"  # The returned Simulation was updated in place.


def test_manager_wait_for_finished_and_display(deck: DeckWriter, capsys: pytest.CaptureFixture[str]) -> None:
    """wait_for FINISHED returns the outcome; the display prints each finished run once."""
    with _manager(workers=2, display=True) as manager:
        sims = [manager.add(deck(), label=f"run{i}", wait_for="FINISHED") for i in range(3)]
        assert all(sim.succeeded and sim.is_finished for sim in sims)
        assert repr(sims[0]) == "Simulation(sim_id=1, deck='deck1.dck', state=FINISHED, status=DONE, 100%)"
    out = capsys.readouterr().out
    assert [out.count(f"run{i}") for i in range(3)] == [1, 1, 1]
    assert "DONE" in out


def test_refresh_releases_finished_simulations(deck: DeckWriter) -> None:
    """Once collected, a finished simulation is released from trnrund but kept here."""
    with _manager() as manager:
        sim = manager.add(deck(), wait_for="FINISHED")
        assert manager.daemon.simulations("FINISHED") == []
        assert manager.simulations == {sim.sim_id: sim}


def test_a_cancelled_queued_simulation_counts_past_running(deck: DeckWriter) -> None:
    """One cancelled before it starts satisfies wait until RUNNING."""
    with _manager() as manager:
        _ = manager.add(deck(gated=True), wait_for="RUNNING")
        queued = manager.add(deck())
        manager.cancel(queued)
        manager.wait(queued, until="RUNNING", timeout=10)
        assert (queued.is_finished, queued.status, queued.started_at) == (True, SimulationStatus.CANCELLED, None)
        manager.cancel(queued)  # Already collected and released: left unchanged, no RequestError.


def test_manager_waits_on_a_simulation_it_did_not_add(deck: DeckWriter) -> None:
    """Wait follows a Simulation from the daemon by simId, though that object is never updated."""
    with _manager() as manager:
        sim = manager.daemon.simulation(manager.daemon.add(deck()))
        manager.wait(sim, timeout=10)
        assert manager.simulations[sim.sim_id].succeeded


def test_manager_rejects_bad_states_before_queuing(deck: DeckWriter) -> None:
    """A wrong wait_for or until raises ValueError and queues nothing."""
    with _manager() as manager:
        with pytest.raises(ValueError, match="not a valid SimulationState"):
            _ = manager.add(deck(), wait_for="DONE")  # pyright: ignore[reportArgumentType]
        with pytest.raises(ValueError, match="not a valid SimulationState"):
            manager.wait(until="DONE")  # pyright: ignore[reportArgumentType]
        assert manager.daemon.simulations("QUEUED") == []
        assert manager.simulations == {}


def test_manager_wait_timeout(deck: DeckWriter) -> None:
    """Wait raises TimeoutError while a simulation is still running."""
    with _manager() as manager:
        sim = manager.add(deck(gated=True))
        with pytest.raises(TimeoutError):
            manager.wait(sim, timeout=0.2)


def test_wait_with_nothing_added_returns_and_close_twice() -> None:
    """Wait on no simulation returns at once; closing again is safe."""
    manager = _manager(display=True)
    manager.wait(timeout=0)
    manager.close()
    manager.close()
