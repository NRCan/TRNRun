"""One simulation as trnrund reports it: its lifecycle, TRNRun status, and TRNSYS logs.

``parse_simulation`` turns a simulation object of a response into a record,
its fields as flat as trnrund's; only its logs are a list of ``LogEvent``.
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from typing import Any, Literal


class SimulationState(StrEnum):
    """Daemon lifecycle, ``QUEUED → RUNNING → FINISHED``; one that never starts goes straight to ``FINISHED``."""

    QUEUED = "QUEUED"
    RUNNING = "RUNNING"
    FINISHED = "FINISHED"


type StateName = SimulationState | Literal["QUEUED", "RUNNING", "FINISHED"]


class SimulationStatus(StrEnum):
    """Runner-reported simulation status."""

    PENDING = "PENDING"
    LAUNCHING = "LAUNCHING"
    RUNNING = "RUNNING"
    DONE = "DONE"
    CANCELLED = "CANCELLED"
    ERROR = "ERROR"
    TIMEOUT = "TIMEOUT"
    STALLED = "STALLED"


class LogSeverity(StrEnum):
    """Severity of a TRNSYS log entry."""

    NOTICE = "Notice"
    WARNING = "Warning"
    FATAL = "Fatal"


@dataclass(frozen=True)
class LogEvent:
    """One TRNSYS log entry; the fields after ``time`` are None unless TRNSYS attached them.

    Attributes
    ----------
    time : float
        Simulation time of the message, in simulated hours.
    unit_id, type_id : int or None
        Unit, and its type, that emitted the message.
    """

    severity: LogSeverity
    time: float
    unit_id: int | None = None
    type_id: int | None = None
    message_code: int | None = None
    message: str | None = None
    information: str | None = None


@dataclass(repr=False)
class Simulation:
    """One simulation as trnrund reported it; a field is None where trnrund sent ``null``.

    Not frozen: a ``SimulationManager`` updates the one ``add()`` returned in place on
    each ``refresh()``. Nothing runs in the background, so it only changes
    during a manager call. ``dataclasses.replace(sim)`` takes a snapshot.

    Attributes
    ----------
    sim_id : int
        ``simId`` the daemon assigned; never reused.
    state : SimulationState
        Daemon lifecycle.
    deck_file : Path
        Absolute deck path.
    label : str or None
        Label it was added with.
    trnrun_args : list of str
        TRNRun options it was added with.
    status, status_message : SimulationStatus or None, str or None
        TRNRun's latest status and its detail. TRNRun can report ``DONE``
        before ``state`` is ``FINISHED``.
    sim_time, percent : float or None
        Latest simulation time, in simulated hours, and completion as a fraction from 0 to 1.
    elapsed_ms, eta_ms : float or None
        Wall-clock milliseconds elapsed since the start, and estimated remaining.
    start_time, stop_time, time_step : float or None
        The deck's start, stop and time step, in simulated hours.
    setting : dict or None
        Settings TRNRun applied, its defaults included, keyed by TRNRun's camelCase names.
    notices, warnings, fatals : int
        Log entries so far, by severity.
    logs : list of LogEvent
        Log entries, oldest first; empty when trnrund sent none, as ``list`` does without ``with_logs``.
    succeeded : bool or None
        Whether it finished with ``DONE``, exit code 0 and no error.
    exit_code : int or None
        TRNRun's exit code.
    error : str or None
        Why the daemon failed or cancelled it.
    submitted_at, started_at, finished_at : datetime or None
        UTC times; ``started_at`` stays None for a simulation that never started.
    """

    sim_id: int
    state: SimulationState
    deck_file: Path
    label: str | None = None
    trnrun_args: list[str] = field(default_factory=list[str])
    status: SimulationStatus | None = None
    status_message: str | None = None
    sim_time: float | None = None
    percent: float | None = None
    elapsed_ms: float | None = None
    eta_ms: float | None = None
    start_time: float | None = None
    stop_time: float | None = None
    time_step: float | None = None
    setting: dict[str, Any] | None = None
    notices: int = 0
    warnings: int = 0
    fatals: int = 0
    logs: list[LogEvent] = field(default_factory=list[LogEvent])
    succeeded: bool | None = None
    exit_code: int | None = None
    error: str | None = None
    submitted_at: datetime | None = None
    started_at: datetime | None = None
    finished_at: datetime | None = None

    def __repr__(self) -> str:
        """Summarize, such as ``Simulation(sim_id=3, deck='a.dck', state=RUNNING, status=RUNNING, 42%)``."""
        percent = "" if self.percent is None else f", {self.percent:.0%}"
        return (
            f"Simulation(sim_id={self.sim_id}, deck={self.deck_file.name!r}, "
            f"state={self.state}, status={self.status}{percent})"
        )

    @property
    def is_finished(self) -> bool:
        """Return whether the daemon finished it; its logs are then complete."""
        return self.state is SimulationState.FINISHED


def _parse_timestamp(value: str | None) -> datetime | None:
    """Parse a UTC timestamp, such as ``2026-10-09T14:03:12.345Z``."""
    return None if value is None else datetime.fromisoformat(value)


def _parse_log(log: dict[str, Any]) -> LogEvent:
    """Parse one log object of a simulation object."""
    return LogEvent(
        severity=LogSeverity(log["severity"]),
        time=log["time"],
        unit_id=log["unitId"],
        type_id=log["typeId"],
        message_code=log["messageCode"],
        message=log["message"],
        information=log["information"],
    )


def parse_simulation(sim: dict[str, Any]) -> Simulation:
    """Parse a simulation object of a trnrund response.

    Parameters
    ----------
    sim : dict
        Simulation object as trnrund sends it, with camelCase keys; ``logs`` may be absent.

    Returns
    -------
    Simulation
        The record; a value TRNRun has not reported yet stays None.

    Raises
    ------
    ValueError
        If the state, status or a log severity is unknown.
    KeyError
        If a field is missing.
    """
    status = sim["trnrunStatus"]
    return Simulation(
        sim_id=sim["simId"],
        state=SimulationState(sim["state"]),
        deck_file=Path(sim["deckFile"]),
        label=sim["label"],
        trnrun_args=sim["trnrunArgs"],
        status=None if status is None else SimulationStatus(status),
        status_message=sim["trnrunMessage"],
        sim_time=sim["simTime"],
        percent=sim["percent"],
        elapsed_ms=sim["elapsedMs"],
        eta_ms=sim["etaMs"],
        start_time=sim["startTime"],
        stop_time=sim["stopTime"],
        time_step=sim["timeStep"],
        setting=sim["setting"],
        notices=sim["notices"],
        warnings=sim["warnings"],
        fatals=sim["fatals"],
        logs=[_parse_log(log) for log in sim.get("logs", [])],
        succeeded=sim["succeeded"],
        exit_code=sim["exitCode"],
        error=sim["error"],
        submitted_at=_parse_timestamp(sim["submittedAt"]),
        started_at=_parse_timestamp(sim["startedAt"]),
        finished_at=_parse_timestamp(sim["finishedAt"]),
    )
