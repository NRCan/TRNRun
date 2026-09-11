# ruff: noqa: D103, S101

from __future__ import annotations

import json
from dataclasses import asdict, fields
from pathlib import Path
from typing import Any, ClassVar

import pytest

import trnrun.manager as manager_module
from trnrun.config import BUNDLED_TRNRUN_PATH, SimulationConfig
from trnrun.events import (
    ConfigEvent,
    EventParseError,
    LogEvent,
    ProgressEvent,
    QueueEvent,
    SettingEvent,
    StatusEvent,
    is_terminal_status,
    parse_event,
    parse_stream_line,
)
from trnrun.simulation import DEFAULT_MAX_LOG_EVENTS, Simulation

FIXTURE_DIR = Path(__file__).parents[2] / "tests" / "fixtures"


def load_fixture(name: str) -> dict[str, Any]:
    """Load one shared JSON contract fixture."""
    with (FIXTURE_DIR / name).open(encoding="utf-8") as fixture_file:
        return json.load(fixture_file)


CONFIG_CONTRACT = load_fixture("config_contract.json")
EVENTS_CONTRACT = load_fixture("events_contract.json")
STATE_CONTRACT = load_fixture("state_contract.json")
INTERLEAVED_EXPECTED = load_fixture("interleaved_expected.json")

EVENT_TYPES = {
    "STATUS": StatusEvent,
    "PROGRESS": ProgressEvent,
    "CONFIG": ConfigEvent,
    "SETTING": SettingEvent,
    "LOG": LogEvent,
    "QUEUE": QueueEvent,
}


def render_cli_args(templates: list[str], trnexe_path: str | Path) -> list[str]:
    """Resolve the shared absolute-path placeholder for Python."""
    absolute_trnexe_path = str(Path(trnexe_path).absolute())
    return [template.replace("{absolute_trnexe_path}", absolute_trnexe_path) for template in templates]


def state_snapshot(simulation: Simulation, *, include_id: bool = False) -> dict[str, Any]:
    """Normalize every public result property represented by the fixtures."""
    snapshot: dict[str, Any] = {
        "accepted": simulation.is_accepted,
        "finished": simulation.is_finished,
        "running": simulation.is_running,
        "has_terminal_status": simulation.has_terminal_status,
        "succeeded": simulation.succeeded,
        "status": asdict(simulation.status) if simulation.status is not None else None,
        "progress": asdict(simulation.progress) if simulation.progress is not None else None,
        "config_event": asdict(simulation.config_event) if simulation.config_event is not None else None,
        "setting_event": asdict(simulation.setting_event) if simulation.setting_event is not None else None,
        "completion_event": asdict(simulation.completion_event) if simulation.completion_event is not None else None,
        "logs": [asdict(event) for event in simulation.logs],
        "log_count": simulation.log_count,
        "notices": simulation.notices,
        "warnings": simulation.warnings,
        "fatals": simulation.fatals,
    }
    if include_id:
        snapshot = {"id": simulation.id, **snapshot}
    return snapshot


def new_simulation(*, sim_id: int = 1, max_log_events: int = DEFAULT_MAX_LOG_EVENTS) -> Simulation:
    """Create process-free state for characterization tests."""
    return Simulation("fixture.dck", SimulationConfig(), sim_id, max_log_events=max_log_events)


def test_config_defaults_and_cli_serialization_match_contract() -> None:
    config = SimulationConfig()
    expected = CONFIG_CONTRACT["defaults"]

    assert {field.name for field in fields(SimulationConfig)} == set(expected)
    assert Path(config.trnrun_path) == BUNDLED_TRNRUN_PATH
    assert Path(config.trnrun_path).name == Path(expected["trnrun_path"].removeprefix("@bundled/")).name
    assert str(config.trnexe_path) == expected["trnexe_path"]
    for field_name, expected_value in expected.items():
        if field_name not in {"trnrun_path", "trnexe_path"}:
            assert getattr(config, field_name) == expected_value

    expected_args = render_cli_args(CONFIG_CONTRACT["defaultCliArgs"], config.trnexe_path)
    assert config.to_cli_args() == expected_args


def test_every_config_option_serializes_as_an_unquoted_argv_element() -> None:
    custom = CONFIG_CONTRACT["custom"]
    config = SimulationConfig(**custom["values"])

    expected_args = render_cli_args(custom["cliArgs"], config.trnexe_path)
    actual_args = config.to_cli_args()

    assert actual_args == expected_args
    assert len(actual_args) == len(fields(SimulationConfig)) - 1
    assert all(argument.startswith("--") for argument in actual_args)
    assert all(not argument.startswith(('"', "'")) and not argument.endswith(('"', "'")) for argument in actual_args)
    assert str(config.trnrun_path) not in "\n".join(actual_args)

    request = CONFIG_CONTRACT["queueRequestTemplate"]
    assert request["runnerArgs"] == custom["cliArgs"]
    assert set(request) == {"runID", "deckFile", "runnerPath", "runnerArgs"}


@pytest.mark.parametrize("bad_value", [0, 1, "false", None])
def test_config_rejects_coercion_for_every_boolean_option(bad_value: object) -> None:
    boolean_fields = [
        field_name for field_name, default_value in CONFIG_CONTRACT["defaults"].items() if type(default_value) is bool
    ]

    for field_name in boolean_fields:
        config = SimulationConfig()
        setattr(config, field_name, bad_value)
        with pytest.raises(TypeError, match="Expected a boolean"):
            config.to_cli_args()


@pytest.mark.parametrize("case", EVENTS_CONTRACT["valid"], ids=lambda case: case["name"])
def test_every_event_kind_normalizes_to_the_contract(case: dict[str, Any]) -> None:
    wire = case["wire"]
    event = parse_event(json.dumps(wire, ensure_ascii=False))

    assert type(event) is EVENT_TYPES[wire["kind"].upper()]
    assert asdict(event) == case["normalized"]


def test_optional_fields_distinguish_protocol_absence_from_normalized_null() -> None:
    cases = {case["name"]: case for case in EVENTS_CONTRACT["valid"]}

    missing_status = parse_event(json.dumps(cases["status-missing-message"]["wire"]))
    null_status = parse_event(json.dumps(cases["status-null-message"]["wire"]))
    absent_log = parse_event(json.dumps(cases["log-optional-fields-absent"]["wire"]))
    null_log = parse_event(json.dumps(cases["log-optional-fields-null"]["wire"]))
    missing_exit = parse_event(json.dumps(cases["queue-accepted-missing-exit-code"]["wire"]))
    null_exit = parse_event(json.dumps(cases["queue-completed-null-exit-code"]["wire"]))

    assert isinstance(missing_status, StatusEvent)
    assert missing_status.message == ""
    assert isinstance(null_status, StatusEvent)
    assert null_status.message == ""
    assert isinstance(absent_log, LogEvent)
    assert isinstance(null_log, LogEvent)
    optional_log_fields = ("time", "unit_id", "type_id", "message_code", "message", "information")
    assert all(getattr(absent_log, field_name) is None for field_name in optional_log_fields)
    assert all(getattr(null_log, field_name) is None for field_name in optional_log_fields)
    assert isinstance(missing_exit, QueueEvent)
    assert missing_exit.exit_code is None
    assert isinstance(null_exit, QueueEvent)
    assert null_exit.exit_code is None


@pytest.mark.parametrize("case", EVENTS_CONTRACT["parseErrors"], ids=lambda case: case["name"])
def test_single_event_parser_rejects_invalid_contract_cases(case: dict[str, str]) -> None:
    with pytest.raises(EventParseError) as error:
        parse_event(case["line"])

    assert case["messageContains"] in str(error.value)


@pytest.mark.parametrize("line", EVENTS_CONTRACT["unroutableStreamLines"])
def test_stream_parser_ignores_non_json_and_unroutable_lines(line: str) -> None:
    assert parse_stream_line(line) is None


@pytest.mark.parametrize("case", EVENTS_CONTRACT["routableStreamErrors"], ids=lambda case: case["name"])
def test_stream_parser_rejects_malformed_routable_events(case: dict[str, str]) -> None:
    with pytest.raises(EventParseError) as error:
        parse_stream_line(case["line"])

    assert case["messageContains"] in str(error.value)


def test_initial_simulation_state_matches_contract() -> None:
    simulation = new_simulation(sim_id=23)

    assert simulation.id == 23
    assert simulation.deck_path == Path("fixture.dck")
    assert isinstance(simulation.config, SimulationConfig)
    assert state_snapshot(simulation) == STATE_CONTRACT["initialState"]


@pytest.mark.parametrize("status", STATE_CONTRACT["terminalStatuses"])
def test_terminal_status_does_not_finish_before_queue_completion(status: str) -> None:
    simulation = new_simulation()
    status_event = StatusEvent(status=status, timestamp=f"status-{status}")
    completion = QueueEvent(event="COMPLETED", run_id="1", timestamp="completed", exit_code=0)

    simulation.apply_event(status_event)
    assert is_terminal_status(status)
    assert simulation.has_terminal_status
    assert simulation.is_running
    assert not simulation.is_finished
    assert not simulation.succeeded

    simulation.apply_event(completion)
    assert not simulation.is_finished
    assert simulation.completion_event is None

    simulation.mark_completed(completion)
    assert simulation.is_finished
    assert not simulation.is_running
    assert simulation.succeeded is (status == STATE_CONTRACT["completionRules"]["successStatus"])

    simulation.apply_event(StatusEvent(status="ERROR", timestamp="after-completion"))
    assert simulation.status == status_event


@pytest.mark.parametrize("status", STATE_CONTRACT["nonterminalStatuses"])
def test_nonterminal_status_remains_nonterminal_even_after_completion(status: str) -> None:
    simulation = new_simulation()
    simulation.apply_event(StatusEvent(status=status, timestamp="nonterminal"))

    assert not is_terminal_status(status)
    assert not simulation.has_terminal_status

    simulation.mark_completed(QueueEvent(event="COMPLETED", run_id="1", timestamp="completed", exit_code=0))
    assert simulation.is_finished
    assert not simulation.has_terminal_status
    assert not simulation.succeeded


def test_completion_without_status_preserves_null_exit_code_and_fails() -> None:
    simulation = new_simulation()
    completion = QueueEvent(event="COMPLETED", run_id="1", timestamp="launch-failed", exit_code=None)

    assert simulation.completion_event is None
    simulation.mark_completed(completion)

    assert simulation.completion_event is completion
    assert simulation.completion_event.exit_code is None
    assert simulation.is_finished
    assert not simulation.has_terminal_status
    assert not simulation.succeeded


def test_default_log_buffer_retains_latest_5000_but_counts_every_event() -> None:
    recipe = STATE_CONTRACT["logStress"]
    simulation = new_simulation(max_log_events=recipe["capacity"])
    severity_cycle = recipe["severityCycle"]

    for index in range(recipe["count"]):
        simulation.apply_event(
            LogEvent(
                severity=severity_cycle[index % len(severity_cycle)],
                timestamp=f"log-{index}",
                message_code=index,
            ),
        )

    logs = simulation.logs
    assert recipe["capacity"] == DEFAULT_MAX_LOG_EVENTS
    assert simulation.log_count == recipe["count"]
    assert len(logs) == recipe["expectedRetained"]
    assert logs[0].message_code == recipe["expectedFirstMessageCode"]
    assert logs[-1].message_code == recipe["expectedLastMessageCode"]
    assert simulation.notices == recipe["expectedCounts"]["Notice"]
    assert simulation.warnings == recipe["expectedCounts"]["Warning"]
    assert simulation.fatals == recipe["expectedCounts"]["Fatal"]

    logs.clear()
    assert len(simulation.logs) == recipe["expectedRetained"]


def test_zero_log_capacity_retains_nothing_but_keeps_counters() -> None:
    simulation = new_simulation(max_log_events=0)
    simulation.apply_event(LogEvent(severity="Warning", timestamp="not-retained"))

    assert simulation.logs == []
    assert simulation.log_count == 1
    assert simulation.warnings == 1


def test_manager_routes_interleaved_fixture_without_processes(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Path,
) -> None:
    raw_lines = (FIXTURE_DIR / "interleaved_stream.jsonl").read_text(encoding="utf-8").splitlines()

    class FixtureQueueProcess:
        instances: ClassVar[list[FixtureQueueProcess]] = []

        def __init__(self, executable: str | Path, max_concurrent: int) -> None:
            self.executable = executable
            self.max_concurrent = max_concurrent
            self.sent: list[dict[str, object]] = []
            self.closed = False
            self.waited = False
            self._lines = iter([f"{line}\n" for line in raw_lines])
            self.instances.append(self)

        def send(self, request: dict[str, object]) -> None:
            self.sent.append(request)

        def read_line(self) -> str | None:
            return next(self._lines, None)

        def close(self) -> None:
            self.closed = True

        def wait(self) -> int:
            self.waited = True
            return 0

    monkeypatch.setattr(manager_module, "QueueProcess", FixtureQueueProcess)

    runner = tmp_path / "custom trnrun.exe"
    trnexe = tmp_path / "custom TrnEXE64.exe"
    first_deck = tmp_path / "first deck.dck"
    second_deck = tmp_path / "second deck.dck"
    for path in (runner, trnexe, first_deck, second_deck):
        path.write_text("fixture", encoding="utf-8")

    custom_values = {
        **CONFIG_CONTRACT["custom"]["values"],
        "trnrun_path": runner,
        "trnexe_path": trnexe,
    }
    caller_config = SimulationConfig(**custom_values)
    manager = manager_module.SimulationManager(max_concurrent=2, refresh_interval=0)

    first = manager.add(first_deck, caller_config)
    second = manager.add(second_deck, caller_config)
    caller_config.severity = "Warning"
    follow_update_ids = [updated.id for updated in manager.follow()]

    assert [simulation.id for simulation in manager.simulations] == INTERLEAVED_EXPECTED["acceptanceOrder"]
    assert follow_update_ids == INTERLEAVED_EXPECTED["followUpdateIds"]
    assert first.config.severity == "Fatal"
    assert second.config.severity == "Fatal"
    assert state_snapshot(first, include_id=True) == INTERLEAVED_EXPECTED["runs"]["1"]
    assert state_snapshot(second, include_id=True) == INTERLEAVED_EXPECTED["runs"]["2"]
    assert manager.succeeded == [first]
    assert manager.failed == [second]

    process = FixtureQueueProcess.instances[0]
    expected_args = render_cli_args(CONFIG_CONTRACT["custom"]["cliArgs"], trnexe)
    assert process.sent == [
        {
            "runID": "1",
            "deckFile": str(first_deck.absolute()),
            "runnerPath": str(runner.absolute()),
            "runnerArgs": expected_args,
        },
        {
            "runID": "2",
            "deckFile": str(second_deck.absolute()),
            "runnerPath": str(runner.absolute()),
            "runnerArgs": expected_args,
        },
    ]

    manager.shutdown()
    assert process.closed
    assert process.waited
