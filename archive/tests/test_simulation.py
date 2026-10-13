# ruff: noqa: S101

from __future__ import annotations

from dataclasses import FrozenInstanceError, replace
from pathlib import Path
from threading import Thread
from typing import override

import pytest

from trnrun.config import SimulationConfig
from trnrun.convenience.simulation import Simulation
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


@pytest.fixture
def config() -> SimulationConfig:
    """Return a configuration that does not require validation."""
    return SimulationConfig()


def make_setting(*, severity: str = "Notice") -> SettingEvent:
    """Build a complete setting event with deterministic values."""
    return SettingEvent(
        trnexe_path="TrnEXE64.exe",
        gui_visibility="hidden",
        wait_for_gui=True,
        wait_for_lst=True,
        wait_for_tmp=False,
        detect_timeout_ms=300_000,
        extra_delay_ms=0,
        watch_log=True,
        watch_tmp=False,
        watch_timeout_ms=0,
        stall_timeout_ms=0,
        poll_ms=100,
        clean_on_success=False,
        kill_on_timeout=False,
        kill_on_stall=False,
        severity=severity,
        write_events=False,
    )


def finished(status: SimulationStatus | None = SimulationStatus.DONE, **changes: object) -> SimulationReply:
    """Build a daemon update for a finished run, successful unless changed."""
    fields: dict[str, object] = {
        "state": SimulationState.FINISHED,
        "exit_code": 0,
        "succeeded": status is SimulationStatus.DONE,
        "status": StatusEvent(status) if status is not None else None,
        **changes,
    }
    return SimulationReply(**fields)  # pyright: ignore[reportArgumentType]


def test_reply_is_immutable() -> None:
    """Parsed daemon state cannot be changed after it is handed to a simulation."""
    update = SimulationReply(SimulationState.RUNNING)

    with pytest.raises(FrozenInstanceError):
        type(update).__setattr__(update, "state", SimulationState.FINISHED)


def test_initial_state_is_queued_and_exposes_input(config: SimulationConfig) -> None:
    """A new simulation starts queued with empty folded state."""
    simulation = Simulation("relative/deck.dck", config, sim_id=7)

    assert simulation.id == 7
    assert simulation.deck_path == Path("relative/deck.dck")
    assert simulation.config is config
    assert simulation.state is SimulationState.QUEUED
    assert not simulation.is_running
    assert not simulation.is_accepted
    assert not simulation.is_finished

    assert not simulation.succeeded
    assert simulation.exit_code is None
    assert simulation.error == ""
    assert simulation.status is None
    assert simulation.status_event is None
    assert simulation.progress is None
    assert simulation.config_event is None
    assert simulation.setting_event is None
    assert simulation.logs == []
    assert simulation.log_count == 0
    assert simulation.notices == 0
    assert simulation.warnings == 0
    assert simulation.fatals == 0


def test_apply_replaces_daemon_state(config: SimulationConfig) -> None:
    """Each update replaces the previous daemon state as a whole."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    status = StatusEvent(SimulationStatus.RUNNING, "started")
    progress = ProgressEvent(5.0, 0.5, 500.0, 500.0)
    config_event = ConfigEvent(0.0, 20.0, 0.5)
    setting = make_setting(severity="Warning")
    first = SimulationReply(SimulationState.ACCEPTED, status=StatusEvent(SimulationStatus.LAUNCHING))
    second = SimulationReply(
        SimulationState.RUNNING,
        setting=setting,
        status=status,
        config=config_event,
        progress=progress,
    )

    simulation.apply(first)
    assert simulation.is_accepted
    assert simulation.status is SimulationStatus.LAUNCHING
    simulation.apply(second)

    assert simulation.state is SimulationState.RUNNING
    assert simulation.status is SimulationStatus.RUNNING
    assert simulation.status_event is status
    assert simulation.progress is progress
    assert simulation.config_event is config_event
    assert simulation.setting_event is setting
    assert simulation.is_running


@pytest.mark.parametrize(
    ("state", "accepted"),
    [
        (SimulationState.QUEUED, False),
        (SimulationState.ACCEPTED, True),
        (SimulationState.RUNNING, True),
        (SimulationState.FINISHED, True),
    ],
)
def test_acceptance_follows_daemon_state(config: SimulationConfig, state: SimulationState, *, accepted: bool) -> None:
    """Any state past QUEUED means a daemon worker slot was reserved."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    simulation.apply(SimulationReply(state))

    assert simulation.is_accepted is accepted
    assert simulation.is_finished is (state is SimulationState.FINISHED)


@pytest.mark.parametrize("state", list(SimulationState))
def test_running_follows_daemon_state(config: SimulationConfig, state: SimulationState) -> None:
    """Queued, accepted, and finished simulations are not running."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    simulation.apply(SimulationReply(state))

    assert simulation.is_running is (state is SimulationState.RUNNING)


def test_log_history_retains_all_events(config: SimulationConfig) -> None:
    """Each batch is appended; history exceeds the former 5,000-event limit and reads return a copy."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    logs = [
        LogEvent("Notice", message="one"),
        LogEvent("Warning", message="two"),
        LogEvent("Fatal", message="three"),
    ] * 1667
    first = SimulationReply(SimulationState.RUNNING, notices=1, warnings=1, fatals=1, logs=tuple(logs[:3]))
    second = SimulationReply(
        SimulationState.RUNNING,
        notices=1667,
        warnings=1667,
        fatals=1667,
        logs=tuple(logs[3:]),
    )

    simulation.apply(first)
    simulation.apply(second)

    snapshot = simulation.logs
    snapshot.clear()

    assert simulation.logs == logs
    assert simulation.log_count == len(logs)
    assert simulation.notices == 1667
    assert simulation.warnings == 1667
    assert simulation.fatals == 1667


@pytest.mark.parametrize(
    ("update", "succeeded"),
    [
        (finished(), True),
        (finished(SimulationStatus.ERROR), False),
        (finished(SimulationStatus.CANCELLED), False),
        (finished(None), False),
        (finished(exit_code=None, error="launch failed", succeeded=False), False),
    ],
)
def test_success_comes_from_the_daemon(
    config: SimulationConfig,
    update: SimulationReply,
    *,
    succeeded: bool,
) -> None:
    """The daemon's verdict, which also checks exit code and errors, is reported unchanged."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    simulation.apply(SimulationReply(SimulationState.RUNNING, status=StatusEvent(SimulationStatus.DONE)))
    assert not simulation.succeeded

    simulation.apply(update)

    assert simulation.is_finished
    assert not simulation.is_running
    assert simulation.succeeded is succeeded
    assert simulation.exit_code == update.exit_code
    assert simulation.error == update.error


def test_info_is_the_latest_reply_replaced_whole(config: SimulationConfig) -> None:
    """Each update swaps in a new frozen reply, without logs, so an earlier read never changes."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    initial = simulation.info
    status = StatusEvent(SimulationStatus.RUNNING)
    progress = ProgressEvent(1.0, 0.1, 100.0, 900.0)
    running = SimulationReply(
        SimulationState.RUNNING,
        setting=make_setting(),
        status=status,
        progress=progress,
        notices=1,
        logs=(LogEvent("Notice", message="retained"),),
    )
    simulation.apply(running)

    info = simulation.info

    assert info == replace(running, logs=())
    assert (info.state, info.status, info.progress) == (SimulationState.RUNNING, status, progress)
    assert initial == SimulationReply(SimulationState.QUEUED)

    simulation.apply(finished(notices=1, warnings=1, logs=(LogEvent("Warning", message="later"),)))

    assert info.state is SimulationState.RUNNING
    assert info.progress is progress
    assert info.warnings == 0
    assert simulation.info.state is SimulationState.FINISHED
    assert simulation.info.logs == ()
    with pytest.raises(FrozenInstanceError):
        type(info).__setattr__(info, "state", SimulationState.QUEUED)


def test_severity_counts_come_from_the_daemon(config: SimulationConfig) -> None:
    """Severity counters are the daemon's, alongside the logs that arrived with them."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    logs = tuple(LogEvent(severity) for severity in ("Notice", "Notice", "Warning", "Fatal"))
    update = SimulationReply(SimulationState.RUNNING, notices=2, warnings=1, fatals=1, logs=logs)
    simulation.apply(update)

    info = simulation.info

    assert (info.notices, info.warnings, info.fatals) == (2, 1, 1)
    assert (simulation.log_count, simulation.notices, simulation.warnings, simulation.fatals) == (4, 2, 1, 1)


def test_final_logs_are_held_before_the_finished_reply(
    config: SimulationConfig,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A reader that sees a run finished already sees its final entries."""
    seen: list[SimulationState] = []

    class ObservedLogs(list[LogEvent]):
        @override
        def extend(self, events: object) -> None:
            super().extend(events)  # pyright: ignore[reportArgumentType]
            seen.append(simulation.state)

    simulation = Simulation("deck.dck", config, sim_id=7)
    monkeypatch.setattr(simulation, "_logs", ObservedLogs())

    simulation.apply(finished(fatals=1, logs=(LogEvent("Fatal"),)))

    assert seen == [SimulationState.QUEUED]
    assert simulation.is_finished
    assert simulation.logs == [LogEvent("Fatal")]


def test_wait_returns_once_settled_and_times_out_before(config: SimulationConfig) -> None:
    """A run settles once its manager has applied its finished reply."""
    simulation = Simulation("deck.dck", config, sim_id=7)

    with pytest.raises(TimeoutError, match="Simulation 7 did not finish within the timeout"):
        simulation.wait(0)

    simulation.apply(finished())
    simulation.settle()
    simulation.wait(0)
    simulation.wait()


def test_wait_from_another_thread_returns_when_settled(config: SimulationConfig) -> None:
    """A waiter blocked in another thread is released by the settle."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    waiter = Thread(target=simulation.wait, args=(10.0,))
    waiter.start()

    simulation.apply(finished())
    simulation.settle()
    waiter.join(10.0)

    assert not waiter.is_alive()


def test_wait_raises_the_error_that_stopped_syncing(config: SimulationConfig) -> None:
    """A run abandoned by its manager raises that error, keeping its last reply."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    simulation.apply(SimulationReply(SimulationState.RUNNING))
    failure = RuntimeError("TRNRun daemon exited with code 1")

    simulation.settle(failure)

    with pytest.raises(RuntimeError) as raised:
        simulation.wait()
    assert raised.value is failure
    assert simulation.state is SimulationState.RUNNING


def test_only_the_first_settle_counts(config: SimulationConfig) -> None:
    """A later shutdown never replaces the error of a failed pull, nor a finish with an error."""
    failed = Simulation("deck.dck", config, sim_id=7)
    failure = RuntimeError("TRNRun daemon exited with code 1")
    failed.settle(failure)
    failed.settle(RuntimeError("SimulationManager is closed"))

    with pytest.raises(RuntimeError) as raised:
        failed.wait(0)
    assert raised.value is failure

    done = Simulation("deck.dck", config, sim_id=8)
    done.settle()
    done.settle(RuntimeError("SimulationManager is closed"))
    done.wait(0)
