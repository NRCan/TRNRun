"""State for one simulation submitted to the TRNRun daemon.

A per-simulation lock synchronizes poller updates and state reads. Use
``snapshot()`` to read multiple fields coherently. The daemon owns the
lifecycle, outcome, and log counters; this object mirrors its latest reply
and accumulates the complete log history.
"""

from __future__ import annotations

from _thread import LockType
from collections.abc import Iterable
from dataclasses import dataclass, replace
from pathlib import Path
from threading import Lock

from trnrun.config import SimulationConfig
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SettingEvent,
    SimulationState,
    SimulationStatus,
    SimulationUpdate,
    StatusEvent,
)


@dataclass(frozen=True)
class SimulationSnapshot:
    """Immutable display state captured under the simulation lock.

    Log history and detailed runner metadata stay on ``Simulation``.
    Capturing this view never copies logs, regardless of history size.
    ``revision`` increases with every change, so an unchanged revision means
    nothing needs redrawing. The first finished snapshot is also the last:
    a finished simulation never changes again.
    """

    id: int
    deck_path: Path
    revision: int
    state: SimulationState
    succeeded: bool
    status: SimulationStatus | None
    message: str
    exit_code: int | None
    error: str
    progress: ProgressEvent | None
    config_event: ConfigEvent | None
    log_count: int
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
        """Return whether the simulation is waiting or running."""
        return not self.is_finished


class Simulation:
    """Synchronized daemon state for one submitted simulation.

    Individual state reads are safe; use ``snapshot()`` for a coherent view of
    multiple fields. Public input attributes ``id``, ``deck_path``, and ``config``
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
        self._update: SimulationUpdate = SimulationUpdate(SimulationState.QUEUED)
        self._revision: int = 0
        # ponytail: Full history uses O(n) memory; spool to disk if logs outgrow RAM.
        self._logs: list[LogEvent] = []

    def apply_update(self, update: SimulationUpdate, logs: Iterable[LogEvent] = ()) -> bool:
        """Replace the daemon state and append new logs, returning whether anything changed.

        `logs` are the entries after those already held, up to the update's
        `log_count`, so the counters always describe the held logs. A finished
        simulation is frozen: later updates return False without changing state.
        """
        new_logs = list(logs)
        with self._lock:
            if self._update.state is SimulationState.FINISHED:
                return False
            if update == self._update and not new_logs:
                return False

            self._update = update
            self._logs.extend(new_logs)
            self._revision += 1
            return True

    def abandon(self, status: SimulationStatus, reason: str) -> bool:
        """Finish a run the daemon can no longer report, returning whether it was unfinished.

        The last polled progress, configuration, and logs are kept. The run
        becomes unsuccessful, with `reason` as both its status message and error.
        """
        with self._lock:
            if self._update.state is SimulationState.FINISHED:
                return False

            self._update = replace(
                self._update,
                state=SimulationState.FINISHED,
                succeeded=False,
                error=reason,
                status=StatusEvent(status, reason),
            )
            self._revision += 1
            return True

    def snapshot(self) -> SimulationSnapshot:
        """Capture coherent display state without copying log history."""
        with self._lock:
            update = self._update
            return SimulationSnapshot(
                id=self.id,
                deck_path=self.deck_path,
                revision=self._revision,
                state=update.state,
                succeeded=update.succeeded,
                status=update.status.status if update.status is not None else None,
                message=update.status.message if update.status is not None else "",
                exit_code=update.exit_code,
                error=update.error,
                progress=update.progress,
                config_event=update.config,
                log_count=len(self._logs),
                notices=update.notices,
                warnings=update.warnings,
                fatals=update.fatals,
            )

    @property
    def state(self) -> SimulationState:
        """Return the daemon lifecycle state."""
        with self._lock:
            return self._update.state

    @property
    def exit_code(self) -> int | None:
        """Return the runner exit code, or None until it exits or if it never launched."""
        with self._lock:
            return self._update.exit_code

    @property
    def error(self) -> str:
        """Return the daemon execution error, or an empty string."""
        with self._lock:
            return self._update.error

    @property
    def status(self) -> SimulationStatus | None:
        """Return the latest runner status."""
        with self._lock:
            return self._update.status.status if self._update.status is not None else None

    @property
    def status_event(self) -> StatusEvent | None:
        """Return the latest status event, including its message."""
        with self._lock:
            return self._update.status

    @property
    def progress(self) -> ProgressEvent | None:
        """Return the latest progress event."""
        with self._lock:
            return self._update.progress

    @property
    def config_event(self) -> ConfigEvent | None:
        """Return the latest simulation configuration event."""
        with self._lock:
            return self._update.config

    @property
    def setting_event(self) -> SettingEvent | None:
        """Return the latest runner setting event."""
        with self._lock:
            return self._update.setting

    @property
    def logs(self) -> list[LogEvent]:
        """Return a copy of all log events, oldest first."""
        with self._lock:
            return list(self._logs)

    @property
    def is_running(self) -> bool:
        """Return whether the simulation is waiting or running."""
        return not self.is_finished

    @property
    def is_accepted(self) -> bool:
        """Return whether a daemon worker slot was reserved for the run."""
        with self._lock:
            return self._update.state is not SimulationState.QUEUED

    @property
    def is_finished(self) -> bool:
        """Return whether the daemon finished the run and its logs were collected."""
        with self._lock:
            return self._update.state is SimulationState.FINISHED

    @property
    def succeeded(self) -> bool:
        """Return whether the run finished with `DONE`, exit code 0, and no error."""
        with self._lock:
            return self._update.succeeded

    @property
    def log_count(self) -> int:
        """Return the total received log count."""
        with self._lock:
            return len(self._logs)

    @property
    def notices(self) -> int:
        """Return the notice count."""
        with self._lock:
            return self._update.notices

    @property
    def warnings(self) -> int:
        """Return the warning count."""
        with self._lock:
            return self._update.warnings

    @property
    def fatals(self) -> int:
        """Return the fatal count."""
        with self._lock:
            return self._update.fatals
