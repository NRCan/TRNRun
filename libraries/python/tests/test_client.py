# ruff: noqa: S101, SLF001

from __future__ import annotations

from pathlib import Path
from threading import Thread
from time import monotonic, sleep
from unittest.mock import Mock

import pytest

import trnrun.client as client_module
from trnrun.client import DaemonClient
from trnrun.events import LogEvent, SimulationReply, SimulationState, SimulationStatus, StatusEvent

TEST_TIMEOUT = 10.0


class ScriptedProcess:
    """Stand-in `DaemonProcess` that records requests and answers from a script."""

    def __init__(self) -> None:
        self.requests: list[dict[str, object]] = []
        self.replies: list[dict[str, object]] = []
        self.shutdown: Mock = Mock()
        self.wait: Mock = Mock()

    def request(self, request: dict[str, object]) -> dict[str, object]:
        """Record the request and return the next scripted reply."""
        self.requests.append(request)
        return self.replies.pop(0) if self.replies else {"ok": True}


def simulation_data(run_id: str, state: str = "RUNNING", **fields: object) -> dict[str, object]:
    """Return one daemon simulation object."""
    return {
        "runId": run_id,
        "deckFile": f"C:\\{run_id}.dck",
        "trnrunArgs": [],
        "state": state,
        "exitCode": None,
        "error": "",
        "setting": None,
        "status": None,
        "config": None,
        "progress": None,
        "logs": [],
        "notices": 0,
        "warnings": 0,
        "fatals": 0,
        "succeeded": False,
        **fields,
    }


@pytest.fixture
def process(monkeypatch: pytest.MonkeyPatch) -> ScriptedProcess:
    """Make every new client talk to a scripted process."""
    scripted = ScriptedProcess()
    monkeypatch.setattr(client_module, "DaemonProcess", Mock(return_value=scripted))
    return scripted


@pytest.fixture
def client(process: ScriptedProcess) -> DaemonClient:
    """Return a client over the scripted process."""
    del process
    return DaemonClient(3, trnrun_path="mock-trnrun.exe", trnrund_path="mock-daemon.exe")


def test_constructor_starts_the_configured_daemon(monkeypatch: pytest.MonkeyPatch) -> None:
    """The daemon gets its executable, the runner, and the concurrency."""
    factory = Mock()
    monkeypatch.setattr(client_module, "DaemonProcess", factory)

    _ = DaemonClient(3, trnrun_path="mock-trnrun.exe", trnrund_path="mock-daemon.exe")

    factory.assert_called_once_with("mock-daemon.exe", "mock-trnrun.exe", 3)


def test_add_sends_the_deck_and_runner_arguments(client: DaemonClient, process: ScriptedProcess) -> None:
    """Paths become strings and arguments a list."""
    client.add("7", Path("C:/decks/model.dck"), ("--watchTmp:true",))
    client.add("8", "model.dck")

    assert process.requests == [
        {"cmd": "add", "runId": "7", "deckFile": str(Path("C:/decks/model.dck")), "trnrunArgs": ["--watchTmp:true"]},
        {"cmd": "add", "runId": "8", "deckFile": "model.dck", "trnrunArgs": []},
    ]


def test_pull_parses_each_simulation(client: DaemonClient, process: ScriptedProcess) -> None:
    """Each pulled simulation is parsed with its new logs."""
    log = {
        "severity": "Warning",
        "time": 5.0,
        "unitId": None,
        "typeId": None,
        "messageCode": None,
        "message": "late",
        "information": None,
    }
    process.replies.append(
        {
            "ok": True,
            "simulations": [
                simulation_data(
                    "1",
                    "FINISHED",
                    status={"status": "DONE", "message": ""},
                    exitCode=0,
                    logs=[log],
                    warnings=2,
                    succeeded=True,
                ),
            ],
        },
    )

    assert client.pull()["1"] == SimulationReply(
        SimulationState.FINISHED,
        exit_code=0,
        status=StatusEvent(SimulationStatus.DONE),
        logs=(LogEvent("Warning", 5.0, message="late"),),
        warnings=2,
        succeeded=True,
    )


def test_pull_keys_the_simulations_by_run_id_in_the_daemons_order(
    client: DaemonClient,
    process: ScriptedProcess,
) -> None:
    """Pull sends only its command and keys the runs by run ID, in the daemon's order."""
    process.replies.append({"ok": True, "simulations": [simulation_data("2"), simulation_data("1", "QUEUED")]})

    simulations = client.pull()

    assert process.requests == [{"cmd": "pull"}]
    assert list(simulations) == ["2", "1"]
    assert simulations["1"].state is SimulationState.QUEUED


@pytest.mark.parametrize(
    ("reply", "message"),
    [
        ({"ok": True}, "'simulations' must be a list of objects"),
        ({"ok": True, "simulations": {}}, "'simulations' must be a list of objects"),
        ({"ok": True, "simulations": [1]}, "'simulations' must be a list of objects"),
        ({"ok": True, "simulations": [{"state": "QUEUED"}]}, "'runId' must be a string"),
    ],
)
def test_malformed_replies_raise_value_error(
    client: DaemonClient,
    process: ScriptedProcess,
    reply: dict[str, object],
    message: str,
) -> None:
    """A reply missing its result fails clearly instead of deep in parsing."""
    process.replies.append(reply)

    with pytest.raises(ValueError, match=message):
        _ = client.pull()


def test_pull_with_a_run_id_names_it(client: DaemonClient, process: ScriptedProcess) -> None:
    """Pulling one run sends its run ID; the reply holds it, or nothing."""
    process.replies.append({"ok": True, "simulations": [simulation_data("2")]})
    process.replies.append({"ok": True, "simulations": []})

    assert list(client.pull("2")) == ["2"]
    assert client.pull("2") == {}
    assert process.requests == [{"cmd": "pull", "runId": "2"}] * 2


def test_shutdown_asks_the_daemon_then_waits_for_its_exit(client: DaemonClient, process: ScriptedProcess) -> None:
    """Graceful shutdown is a request, then a wait, never a kill."""
    client.shutdown(timeout=2.0)

    assert process.requests == [{"cmd": "shutdown"}]
    process.wait.assert_called_once_with(2.0)
    process.shutdown.assert_not_called()


def test_kill_and_context_exit_kill_the_daemon(client: DaemonClient, process: ScriptedProcess) -> None:
    """Kill sends nothing; leaving the context kills too."""
    with client as entered:
        assert entered is client

    process.shutdown.assert_called_once_with()
    assert process.requests == []


# -----------------------------------------------------------------
# Real daemon
# -----------------------------------------------------------------
def _await_state(client: DaemonClient, run_id: str, state: SimulationState) -> tuple[SimulationReply, list[LogEvent]]:
    """Poll until `run_id` reaches `state`, returning its last reply and every log entry the polls returned."""
    deadline = monotonic() + TEST_TIMEOUT
    logs: list[LogEvent] = []
    while True:
        reply = client.pull(run_id).get(run_id)
        if reply is not None:
            logs.extend(reply.logs)
            if reply.state is state:
                return reply, logs
        assert monotonic() < deadline, f"run {run_id} never reached {state}"
        sleep(0.01)


def test_real_daemon_serves_every_command(tmp_path: Path, fake_trnrun: Path) -> None:
    """Add and poll a run to its end through the bundled daemon, which then forgets it."""
    deck = tmp_path / "done-a.dck"
    deck.touch()

    with DaemonClient(1, trnrun_path=fake_trnrun) as client:
        client.add("1", deck)
        with pytest.raises(ValueError, match="Invalid or duplicate runId: 1"):
            client.add("1", deck)
        final, logs = _await_state(client, "1", SimulationState.FINISHED)

        assert client.pull() == {}
        with pytest.raises(ValueError, match="Unknown runId: 1"):
            _ = client.pull("1")  # Forgotten once pulled finished.
        client.add("1", deck)  # Forgotten, so its run ID is free again.

    assert final.succeeded
    assert len(logs) == final.notices + final.warnings + final.fatals == 3


def test_real_daemon_shutdown_finishes_running_runs_before_exiting(tmp_path: Path, fake_trnrun: Path) -> None:
    """Graceful shutdown waits for the running run, which a kill would have stopped."""
    gate = tmp_path / "gate-a.dck"
    queued = tmp_path / "done-b.dck"
    for deck in (gate, queued):
        deck.touch()

    client = DaemonClient(1, trnrun_path=fake_trnrun)
    try:
        client.add("1", gate)
        client.add("2", queued)
        _ = _await_state(client, "1", SimulationState.RUNNING)

        closing = Thread(target=client.shutdown, daemon=True)
        closing.start()
        closing.join(0.2)
        assert closing.is_alive(), "shutdown returned while a run was still going"

        gate.with_suffix(".release").touch()
        closing.join(TEST_TIMEOUT)
        assert not closing.is_alive()
    finally:
        client.kill()

    assert gate.with_suffix(".released").is_file()
    assert client._process._process.returncode == 0
    with pytest.raises(RuntimeError, match="daemon closure"):
        _ = client.pull()
