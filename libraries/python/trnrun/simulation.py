"""State for one simulation submitted to the TRNRun daemon.

A per-simulation lock synchronizes manager updates and state reads. Use
``snapshot()`` to read multiple fields coherently. The daemon owns the
lifecycle, outcome, and log counters; this object mirrors its latest reply
and accumulates the complete log history.
"""

from __future__ import annotations

from _thread import LockType
from dataclasses import dataclass, replace
from pathlib import Path
from threading import Lock

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


@dataclass(frozen=True)
class SimulationSnapshot:
    """Immutable display state captured under the simulation lock.

    Outcome details, log history, and detailed runner metadata stay on ``Simulation``.
    Capturing this view never copies logs, regardless of history size.
    The first finished snapshot is also the last: a finished simulation
    never changes again.
    """

    id: int
    deck_path: Path
    state: SimulationState
    status: SimulationStatus | None
    progress: ProgressEvent | None
    config_event: ConfigEvent | None
    notices: int
    warnings: int
    fatals: int

    @property
    def is_accepted(self) -> bool:
        """Return whether a daemon worker slot was reserved for the run."""
        return self.state is not SimulationState.QUEUED

    @property
    def is_finished(self) -> bool:
        """Return whether the daemon finished the run."""
        return self.state is SimulationState.FINISHED

    @property
    def is_running(self) -> bool:
        """Return whether the daemon lifecycle state is RUNNING."""
        return self.state is SimulationState.RUNNING


class Simulation:
    """Synchronized daemon state for one submitted simulation.

    Mirrors the trnrund ``Simulation``, in the same order. The submission is
    ``id``, ``deck_path``, and ``config``, from which the runner arguments are
    built. The daemon state follows, from ``state`` to ``succeeded``; the
    ``setting``, ``status``, and ``config`` events are named ``setting_event``,
    ``status_event``, and ``config_event``, and ``status`` gives the status
    alone. ``log_count``, ``is_accepted``, ``is_running``, and ``is_finished``
    are conveniences derived from them.

    Individual state reads are safe; use ``snapshot()`` for a coherent view of
    display fields. Public input attributes ``id``, ``deck_path``, and ``config``
    remain caller-owned and should not be mutated concurrently.
    """

    def __init__(
        self,
        deck_path: str | Path,
        config: SimulationConfig,
        sim_id: int,
    ) -> None:
        """Initialize a queued simulation with complete log history."""
        self.id: int = sim_id
        self.deck_path: Path = Path(deck_path)
        self.config: SimulationConfig = config

        self._lock: LockType = Lock()
        self._reply: SimulationReply = SimulationReply(SimulationState.QUEUED)
        self._logs: list[LogEvent] = []

    def apply(self, reply: SimulationReply) -> bool:
        """Replace the daemon state and append the reply's logs, returning whether anything changed.

        The manager calls this with each daemon reply; read the handle instead.
        `reply.logs` start at index `reply.log_start` of the daemon's history:
        entries already held are skipped, so a repeated reply appends nothing,
        and the rest join the history rather than the stored state. A finished
        simulation is frozen: later replies return False without changing state.

        Raises
        ------
        ValueError
            If the reply starts after the held entries, which would leave a gap.
        """
        state = replace(reply, logs=(), log_start=0)
        with self._lock:
            if self._reply.state is SimulationState.FINISHED:
                return False
            held = len(self._logs) - reply.log_start
            if held < 0:
                raise ValueError(f"TRNRun daemon sent log entries from {reply.log_start}, after the {len(self._logs)} held")
            new_logs = reply.logs[held:]
            if state == self._reply and not new_logs:
                return False

            self._reply = state
            self._logs.extend(new_logs)
            return True

    def snapshot(self) -> SimulationSnapshot:
        """Capture coherent display state without copying log history."""
        with self._lock:
            reply = self._reply
            return SimulationSnapshot(
                id=self.id,
                deck_path=self.deck_path,
                state=reply.state,
                status=reply.status.status if reply.status is not None else None,
                progress=reply.progress,
                config_event=reply.config,
                notices=reply.notices,
                warnings=reply.warnings,
                fatals=reply.fatals,
            )

    @property
    def state(self) -> SimulationState:
        """Return the daemon lifecycle state."""
        with self._lock:
            return self._reply.state

    @property
    def exit_code(self) -> int | None:
        """Return the runner exit code, or None until it exits or if it never launched."""
        with self._lock:
            return self._reply.exit_code

    @property
    def error(self) -> str:
        """Return the daemon execution error, or an empty string."""
        with self._lock:
            return self._reply.error

    @property
    def setting_event(self) -> SettingEvent | None:
        """Return the latest runner setting event."""
        with self._lock:
            return self._reply.setting

    @property
    def status(self) -> SimulationStatus | None:
        """Return the latest runner status."""
        with self._lock:
            return self._reply.status.status if self._reply.status is not None else None

    @property
    def status_event(self) -> StatusEvent | None:
        """Return the latest status event, including its message."""
        with self._lock:
            return self._reply.status

    @property
    def config_event(self) -> ConfigEvent | None:
        """Return the latest simulation configuration event."""
        with self._lock:
            return self._reply.config

    @property
    def progress(self) -> ProgressEvent | None:
        """Return the latest progress event."""
        with self._lock:
            return self._reply.progress

    @property
    def logs(self) -> list[LogEvent]:
        """Return a copy of all log events, oldest first."""
        with self._lock:
            return list(self._logs)

    @property
    def notices(self) -> int:
        """Return the notice count."""
        with self._lock:
            return self._reply.notices

    @property
    def warnings(self) -> int:
        """Return the warning count."""
        with self._lock:
            return self._reply.warnings

    @property
    def fatals(self) -> int:
        """Return the fatal count."""
        with self._lock:
            return self._reply.fatals

    @property
    def succeeded(self) -> bool:
        """Return whether the run finished with `DONE`, exit code 0, and no error."""
        with self._lock:
            return self._reply.succeeded

    @property
    def log_count(self) -> int:
        """Return the total received log count."""
        with self._lock:
            return len(self._logs)

    @property
    def is_accepted(self) -> bool:
        """Return whether a daemon worker slot was reserved for the run."""
        with self._lock:
            return self._reply.state is not SimulationState.QUEUED

    @property
    def is_running(self) -> bool:
        """Return whether the daemon lifecycle state is RUNNING."""
        with self._lock:
            return self._reply.state is SimulationState.RUNNING

    @property
    def is_finished(self) -> bool:
        """Return whether the daemon finished the run and its final logs were received."""
        with self._lock:
            return self._reply.state is SimulationState.FINISHED
