"""Daemon against the real trnrund.exe, with Python as the runner."""

import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import pytest

from tests.conftest import PYTHON, DeckWriter, requires_trnrund
from trnrun import (
    Daemon,
    DaemonExitedError,
    LogEvent,
    LogSeverity,
    RequestError,
    Simulation,
    SimulationSettings,
    SimulationState,
    SimulationStatus,
    TrnrunError,
)

pytestmark = requires_trnrund


def _wait_until(daemon: Daemon, sim_id: int, state: SimulationState) -> Simulation:
    """Poll ``simulation`` until the simulation is in ``state``; fail after 10 s."""
    deadline = time.monotonic() + 10
    while (sim := daemon.simulation(sim_id)).state is not state:
        assert time.monotonic() < deadline, f"simulation {sim_id} still {sim.state}"
        time.sleep(0.01)
    return sim


def test_daemon_runs_a_deck_to_the_end(deck: DeckWriter) -> None:
    """add, simulation, simulations and release follow one simulation from queued to forgotten."""
    with Daemon(workers=1, trnrun_path=PYTHON) as daemon:
        sim_id = daemon.add(deck(), label="one")
        _ = _wait_until(daemon, sim_id, SimulationState.FINISHED)
        [sim] = daemon.simulations(SimulationState.FINISHED, with_logs=True)
        assert (sim.sim_id, sim.label, sim.succeeded, sim.exit_code, sim.warnings) == (sim_id, "one", True, 0, 1)
        assert sim.status is SimulationStatus.DONE
        assert (sim.start_time, sim.stop_time, sim.time_step) == (0, 10, 1)
        assert (sim.sim_time, sim.percent, sim.elapsed_ms, sim.eta_ms) == (10, 1, 5, 0)
        assert sim.logs == [LogEvent(LogSeverity.WARNING, 5, unit_id=7, type_id=56, message="careful")]
        assert sim.submitted_at is not None
        assert sim.started_at is not None
        assert sim.finished_at is not None
        assert sim.submitted_at <= sim.started_at <= sim.finished_at
        assert daemon.simulations("FINISHED")[0].logs == []  # Without with_logs.
        assert daemon.simulation(sim_id, with_logs=True) == sim
        assert daemon.simulation(sim_id).logs == []
        daemon.release(sim_id)
        assert daemon.simulations("FINISHED") == []


def test_add_resolves_the_deck_from_pythons_directory(deck: DeckWriter, monkeypatch: pytest.MonkeyPatch) -> None:
    """A relative deck path is made absolute here, not resolved from trnrund's directory; no label stays None."""
    path = deck()
    monkeypatch.chdir(path.parent)
    with Daemon(trnrun_path=PYTHON) as daemon:
        sim = daemon.simulation(daemon.add(path.name))
    assert (sim.deck_file, sim.label) == (path, None)


def test_add_passes_settings_as_trnrun_args(deck: DeckWriter) -> None:
    """The settings' flags are stored with the simulation."""
    settings = SimulationSettings(watch_tmp=True, severity="Fatal")
    with Daemon(trnrun_path=PYTHON) as daemon:
        sim = daemon.simulation(daemon.add(deck(), settings))
    assert sim.trnrun_args == ["--watchTmp:true", "--severity:Fatal"]


def test_add_refuses_a_bad_setting(deck: DeckWriter) -> None:
    """A value TRNRun would reject is refused by trnrund, before queuing."""
    with Daemon(trnrun_path=PYTHON) as daemon:
        with pytest.raises(RequestError, match="guiVisibility"):
            _ = daemon.add(deck(), SimulationSettings(gui_visibility="nope"))  # pyright: ignore[reportArgumentType]
        assert daemon.simulations("QUEUED") == []


def test_a_failed_runner_is_reported(deck: DeckWriter) -> None:
    """A runner that exits without a final status finishes as ERROR, not succeeded."""
    with Daemon(trnrun_path=PYTHON) as daemon:
        sim_id = daemon.add(deck(events=[], exit_code=3))
        sim = _wait_until(daemon, sim_id, SimulationState.FINISHED)
    assert (sim.status, sim.exit_code, sim.succeeded) == (SimulationStatus.ERROR, 3, False)


def test_cancel_queued_and_running(deck: DeckWriter) -> None:
    """Cancel stops a running and a queued simulation; the queued one never starts."""
    with Daemon(workers=1, trnrun_path=PYTHON) as daemon:
        running = daemon.add(deck(gated=True))
        queued = daemon.add(deck())
        _ = _wait_until(daemon, running, SimulationState.RUNNING)
        daemon.cancel(queued)
        daemon.cancel(running)
        for sim_id in (running, queued):
            sim = _wait_until(daemon, sim_id, SimulationState.FINISHED)
            assert (sim.status, sim.succeeded, sim.exit_code) == (SimulationStatus.CANCELLED, False, None)
            assert sim.error is not None
            assert "cancelled" in sim.error
        assert daemon.simulation(queued).started_at is None


def test_cancel_and_release_refuse_the_wrong_state(deck: DeckWriter) -> None:
    """Cancel refuses a finished simulation, release an unfinished one, and both an unknown simId."""
    with Daemon(workers=1, trnrun_path=PYTHON) as daemon:
        sim_id = daemon.add(deck(gated=True))
        with pytest.raises(RequestError):
            daemon.release(sim_id)
        daemon.cancel(sim_id)
        _ = _wait_until(daemon, sim_id, SimulationState.FINISHED)
        with pytest.raises(RequestError):
            daemon.cancel(sim_id)
        daemon.release(sim_id)
        for request in (daemon.cancel, daemon.release, daemon.simulation):
            with pytest.raises(RequestError, match="Unknown simId"):
                _ = request(sim_id)


def test_request_sends_a_raw_request() -> None:
    """A raw request returns trnrund's raw response, or raises RequestError when refused."""
    with Daemon(trnrun_path=PYTHON) as daemon:
        assert daemon.request({"cmd": "ready"}) == {"ok": True}
        with pytest.raises(RequestError):
            _ = daemon.request({"cmd": "nope"})


def test_requests_from_threads_take_turns(deck: DeckWriter) -> None:
    """Concurrent requests never get each other's response."""
    with Daemon(trnrun_path=PYTHON) as daemon:
        sim_ids = [daemon.add(deck()) for _ in range(4)]
        with ThreadPoolExecutor(8) as pool:
            sims = list(pool.map(daemon.simulation, sim_ids * 50))
    assert [sim.sim_id for sim in sims] == sim_ids * 50


def test_daemon_errors(tmp_path: Path) -> None:
    """A refused request raises RequestError; a closed daemon raises DaemonExitedError."""
    daemon = Daemon(trnrun_path=PYTHON)
    with pytest.raises(RequestError, match="Deck file not found"):
        _ = daemon.add(tmp_path / "missing.dck")
    daemon.close()
    daemon.close()
    with pytest.raises(DaemonExitedError, match="code 0"):
        _ = daemon.simulation(1)
    assert issubclass(RequestError, TrnrunError)
    assert issubclass(DaemonExitedError, TrnrunError)


def test_startup_failures(tmp_path: Path) -> None:
    """A missing trnrund raises at once; one that refuses its options exits with code 2 and says why."""
    with pytest.raises(FileNotFoundError):
        _ = Daemon(trnrund_path=tmp_path / "missing.exe")
    with pytest.raises(DaemonExitedError, match=r"code 2: .+"):
        _ = Daemon(trnrun_path=tmp_path / "missing.exe")
    with pytest.raises(DaemonExitedError, match="code 2"):
        _ = Daemon(workers=0, trnrun_path=PYTHON)


def test_close_stops_unfinished_runs_promptly(deck: DeckWriter) -> None:
    """Close kills a running simulation instead of waiting for it."""
    daemon = Daemon(trnrun_path=PYTHON)
    sim_id = daemon.add(deck(gated=True))
    _ = _wait_until(daemon, sim_id, SimulationState.RUNNING)
    start = time.monotonic()
    daemon.close()
    assert time.monotonic() - start < 5
