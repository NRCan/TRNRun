# ruff: noqa: S101

from __future__ import annotations

from pathlib import Path

import pytest

from trnrun.config import SimulationConfig
from trnrun.events import ConfigEvent, LogEvent, ProgressEvent, QueueEvent, SettingEvent, StatusEvent
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
    assert not simulation.has_terminal_status
    assert not simulation.succeeded
    assert simulation.completion_event is None
    assert simulation.status is None
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
    old_status = StatusEvent("LAUNCHING", TIMESTAMP)
    status = StatusEvent("RUNNING", TIMESTAMP, "started")
    old_progress = ProgressEvent(1.0, 0.1, 100.0, 900.0, TIMESTAMP)
    progress = ProgressEvent(5.0, 0.5, 500.0, 500.0, TIMESTAMP)
    old_config = ConfigEvent(0.0, 10.0, 1.0, TIMESTAMP)
    config_event = ConfigEvent(0.0, 20.0, 0.5, TIMESTAMP)
    old_setting = make_setting()
    setting = make_setting(severity="Warning")

    for event in (old_status, old_progress, old_config, old_setting, status, progress, config_event, setting):
        assert simulation.apply_event(event)

    assert simulation.status is status
    assert simulation.progress is progress
    assert simulation.config_event is config_event
    assert simulation.setting_event is setting
    assert simulation.is_running


def test_apply_event_handles_queue_lifecycle(config: SimulationConfig) -> None:
    """Lifecycle events update state once without synthesizing runner status."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    accepted = QueueEvent(event="ACCEPTED", run_id="7", timestamp=TIMESTAMP)
    completed = completion()

    assert simulation.apply_event(accepted)
    assert simulation.is_accepted
    assert not simulation.is_finished
    assert simulation.completion_event is None
    assert not simulation.apply_event(accepted)

    assert simulation.apply_event(completed)
    assert simulation.is_accepted
    assert simulation.is_finished
    assert simulation.completion_event is completed
    assert simulation.status is None
    assert not simulation.succeeded
    assert not simulation.apply_event(completion(exit_code=9))
    assert simulation.completion_event is completed


@pytest.mark.parametrize("is_accepted", [False, True])
def test_apply_event_ignores_unknown_queue_events(config: SimulationConfig, *, is_accepted: bool) -> None:
    """Unrecognized queue events are ignored before and after acceptance."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    if is_accepted:
        assert simulation.apply_event(QueueEvent(event="ACCEPTED", run_id="7", timestamp=TIMESTAMP))

    assert not simulation.apply_event(QueueEvent(event="ENQUEUED", run_id="7", timestamp=TIMESTAMP))

    assert simulation.is_accepted is is_accepted
    assert not simulation.is_finished
    assert simulation.completion_event is None
    assert simulation.status is None


def test_explicit_lifecycle_markers_remain_supported(config: SimulationConfig) -> None:
    """Existing direct state-update methods still preserve first completion."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    completed = completion()

    simulation.mark_accepted()
    simulation.mark_accepted()
    simulation.mark_completed(completed)
    simulation.mark_completed(completion(exit_code=9))

    assert simulation.is_accepted
    assert simulation.is_finished
    assert simulation.completion_event is completed


def test_log_history_is_bounded_but_counts_include_evictions(config: SimulationConfig) -> None:
    """Log retention and case-insensitive severity counters are independent."""
    simulation = Simulation("deck.dck", config, sim_id=7, max_log_events=2)
    logs = [
        LogEvent("Notice", TIMESTAMP, message="one"),
        LogEvent("warning", TIMESTAMP, message="two"),
        LogEvent("FATAL", TIMESTAMP, message="three"),
        LogEvent("Debug", TIMESTAMP, message="four"),
    ]

    for event in logs:
        assert simulation.apply_event(event)

    snapshot = simulation.logs
    snapshot.clear()

    assert simulation.logs == logs[-2:]
    assert simulation.log_count == 4
    assert simulation.notices == 1
    assert simulation.warnings == 1
    assert simulation.fatals == 1


def test_zero_log_capacity_retains_nothing_but_still_counts(config: SimulationConfig) -> None:
    """A zero-sized history drops every log without dropping metrics."""
    simulation = Simulation("deck.dck", config, sim_id=7, max_log_events=0)

    assert simulation.apply_event(LogEvent("Notice", TIMESTAMP))

    assert simulation.logs == []
    assert simulation.log_count == 1
    assert simulation.notices == 1


def test_negative_log_capacity_is_rejected(config: SimulationConfig) -> None:
    """Invalid deque capacity propagates as a constructor error."""
    with pytest.raises(ValueError, match="maxlen must be non-negative"):
        Simulation("deck.dck", config, sim_id=7, max_log_events=-1)


@pytest.mark.parametrize(
    ("status", "terminal", "succeeded"),
    [
        (None, False, False),
        ("RUNNING", False, False),
        ("done", False, False),
        ("DONE", True, True),
        ("ERROR", True, False),
        ("CANCELLED", True, False),
        ("TIMEOUT", True, False),
        ("STALLED", True, False),
    ],
)
def test_completed_result_classification(
    config: SimulationConfig,
    *,
    status: str | None,
    terminal: bool,
    succeeded: bool,
) -> None:
    """Completion and exact runner status jointly determine the outcome."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    if status is not None:
        assert simulation.apply_event(StatusEvent(status, TIMESTAMP))

    assert simulation.has_terminal_status is terminal
    assert not simulation.succeeded

    event = completion(exit_code=9 if status == "DONE" else 0)
    assert simulation.apply_event(event)

    assert not simulation.is_accepted
    assert simulation.completion_event is event
    assert simulation.is_finished
    assert not simulation.is_running
    assert simulation.has_terminal_status is terminal
    assert simulation.succeeded is succeeded


@pytest.mark.parametrize("is_accepted", [False, True])
def test_completion_freezes_state_and_first_completion_metadata(
    config: SimulationConfig,
    *,
    is_accepted: bool,
) -> None:
    """No runner or queue event mutates a finished simulation."""
    simulation = Simulation("deck.dck", config, sim_id=7)
    accepted = QueueEvent(event="ACCEPTED", run_id="7", timestamp=TIMESTAMP)
    running = StatusEvent("RUNNING", TIMESTAMP)
    first_completion = completion(exit_code=None)
    if is_accepted:
        assert simulation.apply_event(accepted)
    assert simulation.apply_event(running)
    assert simulation.apply_event(first_completion)

    for event in (
        StatusEvent("DONE", TIMESTAMP),
        LogEvent("Fatal", TIMESTAMP),
        ConfigEvent(0.0, 10.0, 1.0, TIMESTAMP),
        ProgressEvent(5.0, 0.5, 500.0, 500.0, TIMESTAMP),
        make_setting(),
        accepted,
        completion(exit_code=0),
    ):
        assert not simulation.apply_event(event)

    assert simulation.is_accepted is is_accepted
    assert simulation.config_event is None
    assert simulation.progress is None
    assert simulation.setting_event is None
    assert simulation.status is running
    assert simulation.logs == []
    assert simulation.log_count == 0
    assert simulation.completion_event is first_completion
    assert not simulation.succeeded
