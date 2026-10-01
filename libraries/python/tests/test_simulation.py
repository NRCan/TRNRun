# ruff: noqa: S101

from __future__ import annotations


from concurrent.futures import ThreadPoolExecutor
from dataclasses import FrozenInstanceError
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
    QueueEvent,
    SettingEvent,
    SimulationStatus,
    StatusEvent,
)
from trnrun.simulation import Simulation

TIMESTAMP = "2026-01-02T03:04:05Z"


@pytest.fixture
def config() -> SimulationConfig:
    """Return a configuration that does not require validation."""
    return SimulationConfig()


def make_setting(*, severity: str = "Notice") -> SettingEvent:
    """Build a complete setting event with deterministic values."""
    return SettingEvent(
        timestamp=TIMESTAMP,
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


def completion(*, exit_code: int | None = 0) -> QueueEvent:
    """Build a completion event."""
    return QueueEvent(event="COMPLETED", run_id="7", timestamp=TIMESTAMP, exit_code=exit_code)


def test_initial_state_is_pending_and_exposes_input(config: SimulationConfig) -> None:
    """A new simulation starts pending with empty folded state."""
    simulation = Simulation("relative/deck.dck", config, sim_id=7)

    assert simulation.id == 7
    assert simulation.deck_path == Path("relative/deck.dck")
    assert simulation.config is config
    assert simulation.is_running
    assert not simulation.is_accepted
    assert not simulation.is_finished

    assert not simulation.succeeded
    assert simulation.completion_event is None
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


def test_apply_event_folds_latest_runner_state(config: SimulationConfig) -> None:
    """Each singleton runner event replaces only its matching state."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    old_status = StatusEvent(SimulationStatus.LAUNCHING, TIMESTAMP)
    status = StatusEvent(SimulationStatus.RUNNING, TIMESTAMP, "started")
    old_progress = ProgressEvent(1.0, 0.1, 100.0, 900.0, TIMESTAMP)
    progress = ProgressEvent(5.0, 0.5, 500.0, 500.0, TIMESTAMP)
    old_config = ConfigEvent(0.0, 10.0, 1.0, TIMESTAMP)
    config_event = ConfigEvent(0.0, 20.0, 0.5, TIMESTAMP)
    old_setting = make_setting()
    setting = make_setting(severity="Warning")

    for event in (old_status, old_progress, old_config, old_setting, status, progress, config_event, setting):
        assert simulation.apply_event(event)

    assert simulation.status is SimulationStatus.RUNNING
    assert simulation.status_event is status
    assert simulation.progress is progress
    assert simulation.config_event is config_event
    assert simulation.setting_event is setting
    assert simulation.is_running


def test_queue_events_apply_lifecycle_only_once(config: SimulationConfig) -> None:
    """Acceptance and completion change state, while duplicate or unknown events do not."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    accepted = QueueEvent(event="ACCEPTED", run_id="7", timestamp=TIMESTAMP)
    unknown = QueueEvent(event="ENQUEUED", run_id="7", timestamp=TIMESTAMP)
    finished = completion(exit_code=9)

    assert not simulation.apply_event(unknown)
    assert simulation.apply_event(accepted)
    assert simulation.is_accepted
    assert not simulation.apply_event(accepted)
    assert not simulation.is_finished
    assert simulation.apply_event(finished)
    assert simulation.completion_event is finished
    assert simulation.is_finished
    assert not simulation.succeeded
    assert not simulation.apply_event(completion())
    assert not simulation.apply_event(accepted)
    assert not simulation.apply_event(StatusEvent(SimulationStatus.DONE, TIMESTAMP))
    assert simulation.completion_event is finished
    assert simulation.status is None


def test_log_history_retains_all_events(config: SimulationConfig) -> None:
    """History exceeds the former 5,000-event limit and reads return a copy."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    logs = [
        LogEvent("Notice", TIMESTAMP, message="one"),
        LogEvent("warning", TIMESTAMP, message="two"),
        LogEvent("FATAL", TIMESTAMP, message="three"),
        LogEvent("Debug", TIMESTAMP, message="four"),
    ] * 1251

    for event in logs:
        simulation.apply_event(event)

    snapshot = simulation.logs
    snapshot.clear()

    assert simulation.logs == logs
    assert simulation.snapshot().log_count == len(logs)
    assert simulation.log_count == len(logs)
    assert simulation.notices == 1251
    assert simulation.warnings == 1251
    assert simulation.fatals == 1251



@pytest.mark.parametrize(
    ("status", "succeeded"),
    [
        (None, False),
        (SimulationStatus.PENDING, False),
        (SimulationStatus.LAUNCHING, False),
        (SimulationStatus.RUNNING, False),
        (SimulationStatus.DONE, True),
        (SimulationStatus.ERROR, False),
        (SimulationStatus.CANCELLED, False),
        (SimulationStatus.TIMEOUT, False),
        (SimulationStatus.STALLED, False),
    ],
)
def test_completed_result_classification(
    config: SimulationConfig,
    *,
    status: SimulationStatus | None,

    succeeded: bool,
) -> None:
    """Completion and exact runner status jointly determine the outcome."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    if status is not None:
        simulation.apply_event(StatusEvent(status, TIMESTAMP))

    assert not simulation.succeeded
    pending = simulation.snapshot()
    assert pending.status is status

    assert pending.is_running
    assert not pending.is_finished
    assert not pending.succeeded

    event = completion(exit_code=9 if status is SimulationStatus.DONE else 0)
    assert simulation.apply_event(event)

    assert simulation.completion_event is event
    assert simulation.is_finished
    assert not simulation.is_running
    assert simulation.succeeded is succeeded
    snapshot = simulation.snapshot()

    assert snapshot.status is status
    assert snapshot.is_finished
    assert not snapshot.is_running

    assert snapshot.succeeded is succeeded


def test_completion_freezes_state_and_first_completion_metadata(config: SimulationConfig) -> None:
    """No runner event or duplicate completion mutates a finished simulation."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    running = StatusEvent(SimulationStatus.RUNNING, TIMESTAMP)
    first_completion = completion(exit_code=None)
    simulation.apply_event(running)
    assert simulation.apply_event(first_completion)

    assert not simulation.apply_event(StatusEvent(SimulationStatus.DONE, TIMESTAMP))
    assert not simulation.apply_event(LogEvent("Fatal", TIMESTAMP))
    assert not simulation.apply_event(completion(exit_code=0))

    assert simulation.status is SimulationStatus.RUNNING
    assert simulation.status_event is running
    assert simulation.logs == []
    assert simulation.log_count == 0
    assert simulation.completion_event is first_completion
    assert not simulation.succeeded


def test_snapshot_captures_state_and_stays_stable(config: SimulationConfig) -> None:
    """Snapshots retain only display state, independently of later updates."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    initial = simulation.snapshot()
    status = StatusEvent(SimulationStatus.RUNNING, TIMESTAMP)
    progress = ProgressEvent(1.0, 0.1, 100.0, 900.0, TIMESTAMP)
    config_event = ConfigEvent(0.0, 10.0, 1.0, TIMESTAMP)
    setting = make_setting()
    log = LogEvent("Notice", TIMESTAMP, message="retained")
    assert simulation.apply_event(QueueEvent(event="ACCEPTED", run_id="7", timestamp=TIMESTAMP))
    for event in (status, progress, config_event, setting, log):
        simulation.apply_event(event)

    snapshot = simulation.snapshot()

    assert isinstance(snapshot, SimulationSnapshot)
    assert snapshot.id == 7
    assert snapshot.deck_path == Path("deck.dck")
    assert snapshot.is_accepted
    assert not snapshot.is_finished
    assert snapshot.status is status.status
    assert snapshot.progress is progress
    assert snapshot.config_event is config_event
    assert (snapshot.log_count, snapshot.notices, snapshot.warnings, snapshot.fatals) == (1, 1, 0, 0)
    for name in ("config", "logs", "status_event", "setting_event", "completion_event"):
        assert not hasattr(snapshot, name)

    simulation.apply_event(StatusEvent(SimulationStatus.DONE, TIMESTAMP))
    simulation.apply_event(ProgressEvent(10.0, 1.0, 1_000.0, 0.0, TIMESTAMP))
    simulation.apply_event(ConfigEvent(0.0, 20.0, 0.5, TIMESTAMP))
    simulation.apply_event(make_setting(severity="Warning"))
    simulation.apply_event(LogEvent("Warning", TIMESTAMP, message="replacement"))
    assert simulation.apply_event(completion())

    assert snapshot.status is status.status
    assert snapshot.progress is progress
    assert snapshot.config_event is config_event
    assert snapshot.is_running
    assert not snapshot.succeeded
    assert (snapshot.log_count, snapshot.notices, snapshot.warnings, snapshot.fatals) == (1, 1, 0, 0)
    assert not initial.is_accepted
    assert initial.status is None
    assert initial.log_count == 0
    assert initial.is_running
    assert simulation.snapshot().succeeded


@pytest.mark.parametrize("field", ["id", "deck_path", "status", "log_count", "is_accepted", "is_finished"])
def test_snapshot_is_frozen(config: SimulationConfig, field: str) -> None:
    """Snapshot fields cannot be reassigned or deleted."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    simulation.apply_event(LogEvent("Notice", TIMESTAMP))
    snapshot = simulation.snapshot()

    with pytest.raises(FrozenInstanceError):
        setattr(snapshot, field, None)
    with pytest.raises(FrozenInstanceError):
        delattr(snapshot, field)



def test_snapshot_counts_include_unknown_severities(config: SimulationConfig) -> None:
    """Snapshots preserve total and case-insensitive severity counts."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    logs = tuple(LogEvent(severity, TIMESTAMP) for severity in ("Notice", "warning", "FATAL", "Debug"))
    for event in logs:
        simulation.apply_event(event)

    snapshot = simulation.snapshot()

    assert (snapshot.log_count, snapshot.notices, snapshot.warnings, snapshot.fatals) == (4, 1, 1, 1)


def test_snapshot_does_not_iterate_history(
    config: SimulationConfig,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Rendering snapshots skip copying history rather than copying and discarding it."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    simulation.apply_event(LogEvent("Notice", TIMESTAMP))
    expected = simulation.snapshot()
    history = MagicMock(spec=list)
    history.__len__.return_value = 1
    history.__iter__.side_effect = AssertionError("Log history must not be copied")
    monkeypatch.setattr(simulation, "_logs", history)

    assert simulation.snapshot() == expected
    history.__iter__.assert_not_called()


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
    ["snapshot", "logs", "log_count", "notices", "warnings", "fatals"],
)
def test_reads_wait_for_atomic_log_and_counter_update(
    config: SimulationConfig,
    monkeypatch: pytest.MonkeyPatch,
    read: str,
) -> None:
    """A reader cannot observe a log append before its severity counter update."""
    appended = Event()
    resume = Event()
    lock = ObservedLock()

    class PausingLogs(list[LogEvent]):
        @override
        def append(self, event: LogEvent) -> None:
            super().append(event)
            appended.set()
            assert resume.wait(timeout=5), "Writer was not released"

    simulation = Simulation("deck.dck", config, sim_id=7)
    monkeypatch.setattr(simulation, "_lock", lock)
    monkeypatch.setattr(simulation, "_logs", PausingLogs())
    log = LogEvent("Warning", TIMESTAMP)

    def read_state() -> object:
        if read == "snapshot":
            return simulation.snapshot()

        return getattr(simulation, read)

    with ThreadPoolExecutor(max_workers=2) as executor:
        writer = executor.submit(simulation.apply_event, log)
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
    assert (snapshot.log_count, snapshot.notices, snapshot.warnings, snapshot.fatals) == (1, 0, 1, 0)
