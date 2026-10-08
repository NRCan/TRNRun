# ruff: noqa: S101

from __future__ import annotations

from concurrent.futures import ThreadPoolExecutor
from dataclasses import FrozenInstanceError, replace
from pathlib import Path
from threading import Event, Lock
from types import TracebackType
from typing import Self, override
from unittest.mock import MagicMock

import pytest

from trnrun import SimulationSnapshot
from trnrun.config import SimulationConfig
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
from trnrun.simulation import Simulation


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

    assert simulation.apply(first)
    assert simulation.is_accepted
    assert simulation.status is SimulationStatus.LAUNCHING
    assert simulation.apply(second)

    assert simulation.state is SimulationState.RUNNING
    assert simulation.status is SimulationStatus.RUNNING
    assert simulation.status_event is status
    assert simulation.progress is progress
    assert simulation.config_event is config_event
    assert simulation.setting_event is setting
    assert simulation.is_running
    assert not simulation.apply(second)


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
    _ = simulation.apply(SimulationReply(state))

    assert simulation.is_accepted is accepted
    assert simulation.snapshot().is_accepted is accepted
    assert simulation.is_finished is (state is SimulationState.FINISHED)


@pytest.mark.parametrize("state", list(SimulationState))
def test_running_follows_daemon_state(config: SimulationConfig, state: SimulationState) -> None:
    """Queued, accepted, and finished simulations are not running."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    _ = simulation.apply(SimulationReply(state))

    assert simulation.is_running is (state is SimulationState.RUNNING)
    assert simulation.snapshot().is_running is (state is SimulationState.RUNNING)


def test_log_history_retains_all_events(config: SimulationConfig) -> None:
    """History exceeds the former 5,000-event limit and reads return a copy."""
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
        log_start=3,
    )

    assert simulation.apply(first)
    assert simulation.apply(second)
    assert not simulation.apply(replace(second, logs=()))

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
    assert simulation.apply(SimulationReply(SimulationState.RUNNING, status=StatusEvent(SimulationStatus.DONE)))
    assert not simulation.succeeded

    assert simulation.apply(update)

    assert simulation.is_finished
    assert not simulation.is_running
    assert simulation.succeeded is succeeded
    assert simulation.exit_code == update.exit_code
    assert simulation.error == update.error
    snapshot = simulation.snapshot()
    assert snapshot.is_finished
    assert not snapshot.is_running


def test_finished_simulation_is_frozen(config: SimulationConfig) -> None:
    """No later update or log mutates a finished simulation."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    first = finished(SimulationStatus.ERROR, exit_code=None, error="launch failed", fatals=1, logs=(LogEvent("Fatal"),))
    assert simulation.apply(first)

    assert not simulation.apply(finished(logs=(LogEvent("Notice"),)))
    assert not simulation.apply(SimulationReply(SimulationState.RUNNING))

    assert simulation.status is SimulationStatus.ERROR
    assert simulation.error == "launch failed"
    assert simulation.exit_code is None
    assert simulation.logs == [LogEvent("Fatal")]
    assert not simulation.succeeded


def test_snapshot_captures_state_and_stays_stable(config: SimulationConfig) -> None:
    """Snapshots retain only display state, independently of later updates."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    initial = simulation.snapshot()
    progress = ProgressEvent(1.0, 0.1, 100.0, 900.0)
    config_event = ConfigEvent(0.0, 10.0, 1.0)
    running = SimulationReply(
        SimulationState.RUNNING,
        setting=make_setting(),
        status=StatusEvent(SimulationStatus.RUNNING),
        config=config_event,
        progress=progress,
        notices=1,
        logs=(LogEvent("Notice", message="retained"),),
    )
    assert simulation.apply(running)

    snapshot = simulation.snapshot()

    assert isinstance(snapshot, SimulationSnapshot)
    assert snapshot.id == 7
    assert snapshot.deck_path == Path("deck.dck")
    assert snapshot.state is SimulationState.RUNNING
    assert snapshot.is_accepted
    assert not snapshot.is_finished
    assert snapshot.status is SimulationStatus.RUNNING
    assert snapshot.progress is progress
    assert snapshot.config_event is config_event
    assert (snapshot.notices, snapshot.warnings, snapshot.fatals) == (1, 0, 0)
    for name in (
        "config",
        "logs",
        "status_event",
        "setting_event",
        "succeeded",
        "message",
        "exit_code",
        "error",
        "log_count",
    ):
        assert not hasattr(snapshot, name)

    final = finished(
        progress=ProgressEvent(10.0, 1.0, 1_000.0, 0.0),
        config=ConfigEvent(0.0, 20.0, 0.5),
        notices=1,
        warnings=1,
        logs=(LogEvent("Warning", message="later"),),
        log_start=1,
    )
    assert simulation.apply(final)

    assert snapshot.status is SimulationStatus.RUNNING
    assert snapshot.progress is progress
    assert snapshot.config_event is config_event
    assert snapshot.is_running
    assert (snapshot.notices, snapshot.warnings, snapshot.fatals) == (1, 0, 0)
    assert not initial.is_accepted
    assert initial.status is None
    assert (initial.notices, initial.warnings, initial.fatals) == (0, 0, 0)
    assert not initial.is_running
    assert simulation.succeeded


def test_outcome_details_stay_on_simulation(config: SimulationConfig) -> None:
    """The display snapshot reports status; the simulation retains outcome details."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    update = finished(SimulationStatus.ERROR, exit_code=3, error="capture failed")
    assert simulation.apply(replace(update, status=StatusEvent(SimulationStatus.ERROR, "TRNSYS stopped")))

    snapshot = simulation.snapshot()

    assert snapshot.status is SimulationStatus.ERROR
    assert simulation.status_event == StatusEvent(SimulationStatus.ERROR, "TRNSYS stopped")
    assert (simulation.exit_code, simulation.error) == (3, "capture failed")


def test_apply_reports_only_changes(config: SimulationConfig) -> None:
    """Only state changes and new logs count as updates; finished runs stay frozen."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    running = SimulationReply(SimulationState.RUNNING)

    assert simulation.apply(running)
    assert not simulation.apply(running)
    assert simulation.apply(replace(running, logs=(LogEvent("Notice"),)))
    assert simulation.apply(finished())
    assert not simulation.apply(SimulationReply(SimulationState.RUNNING))


def test_log_batches_are_placed_by_their_start(config: SimulationConfig) -> None:
    """Entries already held are skipped, so a repeated batch is no change, and identical new entries still join."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    entry = LogEvent("Warning", 5.0, message="repeated")
    update = SimulationReply(SimulationState.RUNNING, warnings=1, logs=(entry,))

    assert simulation.apply(update)
    assert not simulation.apply(update)
    overlapping = replace(update, warnings=2, logs=(entry, entry))
    assert simulation.apply(overlapping)
    assert not simulation.apply(replace(overlapping, logs=(entry,), log_start=1))
    assert simulation.logs == [entry, entry]


def test_log_batch_after_a_gap_raises(config: SimulationConfig) -> None:
    """A batch starting past the held entries would lose some, so it is rejected unapplied."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    gap = SimulationReply(SimulationState.RUNNING, warnings=2, logs=(LogEvent("Warning"),), log_start=1)

    with pytest.raises(ValueError, match="from 1, after the 0 held"):
        _ = simulation.apply(gap)

    assert simulation.state is SimulationState.QUEUED
    assert simulation.logs == []


@pytest.mark.parametrize(
    "field",
    ["id", "deck_path", "state", "status", "progress", "config_event", "notices", "warnings", "fatals"],
)
def test_snapshot_is_frozen(config: SimulationConfig, field: str) -> None:
    """Snapshot fields cannot be reassigned or deleted."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    _ = simulation.apply(SimulationReply(SimulationState.RUNNING, notices=1, logs=(LogEvent("Notice"),)))
    snapshot = simulation.snapshot()

    with pytest.raises(FrozenInstanceError):
        setattr(snapshot, field, None)
    with pytest.raises(FrozenInstanceError):
        delattr(snapshot, field)


def test_severity_counts_come_from_the_daemon(config: SimulationConfig) -> None:
    """Severity counters are the daemon's, alongside the logs that arrived with them."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    logs = tuple(LogEvent(severity) for severity in ("Notice", "Notice", "Warning", "Fatal"))
    update = SimulationReply(SimulationState.RUNNING, notices=2, warnings=1, fatals=1, logs=logs)
    _ = simulation.apply(update)

    snapshot = simulation.snapshot()

    assert (snapshot.notices, snapshot.warnings, snapshot.fatals) == (2, 1, 1)
    assert (simulation.log_count, simulation.notices, simulation.warnings, simulation.fatals) == (4, 2, 1, 1)


def test_snapshot_does_not_access_history(
    config: SimulationConfig,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Display snapshots read only folded state, without touching log history."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    _ = simulation.apply(SimulationReply(SimulationState.RUNNING, notices=1, logs=(LogEvent("Notice"),)))
    expected = simulation.snapshot()
    history = MagicMock(spec=list)
    history.__len__.side_effect = AssertionError("Log history must not be counted")
    history.__iter__.side_effect = AssertionError("Log history must not be copied")
    monkeypatch.setattr(simulation, "_logs", history)

    assert simulation.snapshot() == expected
    history.__iter__.assert_not_called()
    history.__len__.assert_not_called()


class ObservedLock:
    """Expose actual cross-thread contention without relying on sleeps."""

    def __init__(self) -> None:
        self.lock = Lock()
        self.contended = Event()

    def __enter__(self) -> Self:
        """Acquire the lock and signal if another thread holds it."""
        if not self.lock.acquire(blocking=False):
            self.contended.set()
            self.lock.acquire()
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Release the lock."""
        self.lock.release()


@pytest.mark.parametrize(
    "read",
    ["snapshot", "logs", "log_count", "notices", "warnings", "fatals", "state"],
)
def test_reads_wait_for_atomic_log_and_state_update(
    config: SimulationConfig,
    monkeypatch: pytest.MonkeyPatch,
    read: str,
) -> None:
    """A reader cannot observe new logs before their counters and state."""
    appended = Event()
    resume = Event()
    lock = ObservedLock()

    class PausingLogs(list[LogEvent]):
        @override
        def extend(self, events: object) -> None:
            super().extend(events)  # pyright: ignore[reportArgumentType]
            appended.set()
            assert resume.wait(timeout=5), "Writer was not released"

    simulation = Simulation("deck.dck", config, sim_id=7)
    monkeypatch.setattr(simulation, "_lock", lock)
    monkeypatch.setattr(simulation, "_logs", PausingLogs())
    update = SimulationReply(SimulationState.RUNNING, warnings=1, logs=(LogEvent("Warning"),))

    def read_state() -> object:
        if read == "snapshot":
            return simulation.snapshot()

        return getattr(simulation, read)

    with ThreadPoolExecutor(max_workers=2) as executor:
        writer = executor.submit(simulation.apply, update)
        try:
            assert appended.wait(timeout=5), "Writer did not reach the partial update"
            reader = executor.submit(read_state)
            assert lock.contended.wait(timeout=5), "Reader did not acquire the update lock"
            assert not reader.done()
        finally:
            resume.set()
        assert writer.result(timeout=5)
        assert reader.result(timeout=5) == read_state()

    snapshot = simulation.snapshot()
    assert snapshot.state is SimulationState.RUNNING
    assert (snapshot.notices, snapshot.warnings, snapshot.fatals) == (0, 1, 0)
