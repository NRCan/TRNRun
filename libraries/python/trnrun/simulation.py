"""State for one simulation submitted through TRNRun Queue.

A per-simulation lock synchronizes reader-thread updates and state reads. Use
``snapshot()`` to read multiple fields coherently. Runner outcomes and queue
completion metadata are retained without synthesizing events.
"""

from __future__ import annotations

from _thread import LockType
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
from threading import Lock

from trnrun.config import SimulationConfig
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    QueueEvent,
    SettingEvent,
    SimulationStatus,
    StatusEvent,
    TrnRunEvent,
)


@dataclass(frozen=True)
class SimulationSnapshot:
    """Immutable display state captured under the simulation lock.

    Log history and detailed runner/queue metadata stay on ``Simulation``.
    Capturing this view never copies logs, regardless of history size.
    """

    id: int
    deck_path: Path
    is_accepted: bool
    is_finished: bool
    status: SimulationStatus | None
    progress: ProgressEvent | None
    config_event: ConfigEvent | None
    log_count: int
    notices: int
    warnings: int
    fatals: int

    @property
    def is_running(self) -> bool:
        """Return whether the simulation is waiting or running."""
        return not self.is_finished

    @property
    def succeeded(self) -> bool:
        """Return whether a completed run has the terminal status `DONE`."""
        return self.is_finished and self.status is SimulationStatus.DONE


class Simulation:
    """Synchronized event state for one queued simulation.

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
        """Initialize a pending simulation with complete log history."""
        self.id: int = sim_id
        self.deck_path: Path = Path(deck_path)
        self.config: SimulationConfig = config

        self._lock: LockType = Lock()
        self._accepted: bool = False
        self._completion_event: QueueEvent | None = None
        self._status_event: StatusEvent | None = None
        self._progress_event: ProgressEvent | None = None
        self._config_event: ConfigEvent | None = None
        self._setting_event: SettingEvent | None = None
        # ponytail: Full history uses O(n) memory; spool to disk if logs outgrow RAM.
        self._logs: list[LogEvent] = []
        self._severity_counts: Counter[str] = Counter()

    def apply_event(self, event: TrnRunEvent) -> bool:
        """Apply one runner or queue event, returning whether it was applied.

        Duplicate acceptance, unrecognized queue events, and all events after
        completion return False without changing state. Queue completion records
        metadata; success still depends on the runner's terminal status.
        """
        with self._lock:
            if self._completion_event is not None:
                return False

            match event:
                case StatusEvent():
                    self._status_event = event
                case ConfigEvent():
                    self._config_event = event
                case SettingEvent():
                    self._setting_event = event
                case ProgressEvent():
                    self._progress_event = event
                case LogEvent():
                    self._logs.append(event)
                    self._severity_counts[event.severity.lower()] += 1
                case QueueEvent(event="ACCEPTED") if not self._accepted:
                    self._accepted = True
                case QueueEvent(event="COMPLETED"):
                    self._completion_event = event
                case QueueEvent():
                    return False

            return True

    def snapshot(self) -> SimulationSnapshot:
        """Capture coherent display state without copying log history."""
        with self._lock:
            return SimulationSnapshot(
                id=self.id,
                deck_path=self.deck_path,
                is_accepted=self._accepted,
                is_finished=self._completion_event is not None,
                status=self._status_event.status if self._status_event is not None else None,
                progress=self._progress_event,
                config_event=self._config_event,
                log_count=len(self._logs),
                notices=self._severity_counts["notice"],
                warnings=self._severity_counts["warning"],
                fatals=self._severity_counts["fatal"],
            )

    @property
    def completion_event(self) -> QueueEvent | None:
        """Return QUEUE/COMPLETED metadata, or None if not received.

        The event's exit_code is None when the runner could not be launched.
        A missing event instead means the run has not been marked finished.
        """
        with self._lock:
            return self._completion_event

    @property
    def status(self) -> SimulationStatus | None:
        """Return the latest runner status."""
        with self._lock:
            return self._status_event.status if self._status_event is not None else None

    @property
    def status_event(self) -> StatusEvent | None:
        """Return the latest status event, including its metadata."""
        with self._lock:
            return self._status_event

    @property
    def progress(self) -> ProgressEvent | None:
        """Return the latest progress event."""
        with self._lock:
            return self._progress_event

    @property
    def config_event(self) -> ConfigEvent | None:
        """Return the latest simulation configuration event."""
        with self._lock:
            return self._config_event

    @property
    def setting_event(self) -> SettingEvent | None:
        """Return the latest runner setting event."""
        with self._lock:
            return self._setting_event

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
        """Return whether a queue worker picked the simulation up."""
        with self._lock:
            return self._accepted

    @property
    def is_finished(self) -> bool:
        """Return whether the queue reported completion for this run."""
        with self._lock:
            return self._completion_event is not None

    @property
    def succeeded(self) -> bool:
        """Return whether a completed run has the terminal status `DONE`."""
        with self._lock:
            return (
                self._completion_event is not None
                and self._status_event is not None
                and self._status_event.status is SimulationStatus.DONE
            )

    @property
    def log_count(self) -> int:
        """Return the total received log count."""
        with self._lock:
            return len(self._logs)

    @property
    def notices(self) -> int:
        """Return the notice count."""
        with self._lock:
            return self._severity_counts["notice"]

    @property
    def warnings(self) -> int:
        """Return the warning count."""
        with self._lock:
            return self._severity_counts["warning"]

    @property
    def fatals(self) -> int:
        """Return the fatal count."""
        with self._lock:
            return self._severity_counts["fatal"]
