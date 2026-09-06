"""Thread-safe state for one simulation submitted through TRNRun Queue."""

from __future__ import annotations

import threading
from collections import Counter, deque
from dataclasses import dataclass
from pathlib import Path
from typing import Final

from trnrun.config import SimulationConfig
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    SettingEvent,
    StatusEvent,
    TrnRunEvent,
    is_terminal_status,
)

DEFAULT_MAX_LOG_EVENTS: Final[int] = 5000


@dataclass(frozen=True)
class SimulationSnapshot:
    """Consistent view of a simulation's current state."""

    id: int
    deck_path: Path
    status: StatusEvent | None
    progress: ProgressEvent | None
    config_event: ConfigEvent | None
    setting_event: SettingEvent | None
    notices: int
    warnings: int
    fatals: int
    log_count: int


class Simulation:
    """Thread-safe event state for one queued simulation."""

    def __init__(
        self,
        deck_path: str | Path,
        config: SimulationConfig,
        sim_id: int,
        max_log_events: int = DEFAULT_MAX_LOG_EVENTS,
    ) -> None:
        """Initialize a pending simulation."""
        self.id: int = sim_id
        self.deck_path: Path = Path(deck_path)
        self.config: SimulationConfig = config

        self._lock: threading.Lock = threading.Lock()
        self._finished: threading.Event = threading.Event()
        self._status: StatusEvent | None = None
        self._progress: ProgressEvent | None = None
        self._config_event: ConfigEvent | None = None
        self._setting_event: SettingEvent | None = None
        self._logs: deque[LogEvent] = deque(maxlen=max_log_events)
        self._severity_counts: Counter[str] = Counter()

    def apply_event(self, event: TrnRunEvent) -> None:
        """Fold one runner event into the simulation state."""
        with self._lock:
            match event:
                case StatusEvent():
                    self._status = event
                    if is_terminal_status(event.status):
                        self._finished.set()
                case ConfigEvent():
                    self._config_event = event
                case SettingEvent():
                    self._setting_event = event
                case ProgressEvent():
                    self._progress = event
                case LogEvent():
                    self._logs.append(event)
                    self._severity_counts[event.severity.lower()] += 1

    def wait(self, timeout: float | None = None) -> bool:
        """Wait for a terminal status event."""
        return self._finished.wait(timeout)

    def snapshot(self) -> SimulationSnapshot:
        """Return a consistent snapshot of the simulation."""
        with self._lock:
            return SimulationSnapshot(
                id=self.id,
                deck_path=self.deck_path,
                status=self._status,
                progress=self._progress,
                config_event=self._config_event,
                setting_event=self._setting_event,
                notices=self._count_severity("notice"),
                warnings=self._count_severity("warn"),
                fatals=self._count_severity("fatal"),
                log_count=sum(self._severity_counts.values()),
            )

    @property
    def status(self) -> StatusEvent | None:
        """Return the latest status event."""
        with self._lock:
            return self._status

    @property
    def progress(self) -> ProgressEvent | None:
        """Return the latest progress event."""
        with self._lock:
            return self._progress

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
        """Return retained log events."""
        with self._lock:
            return list(self._logs)

    @property
    def is_running(self) -> bool:
        """Return whether the simulation is waiting or running."""
        return not self._finished.is_set()

    @property
    def is_finished(self) -> bool:
        """Return whether a terminal status was received."""
        return self._finished.is_set()

    @property
    def succeeded(self) -> bool:
        """Return whether the terminal status is `DONE`."""
        with self._lock:
            return self._status is not None and self._status.status.upper() == "DONE"

    @property
    def log_count(self) -> int:
        """Return the total number of log events."""
        with self._lock:
            return sum(self._severity_counts.values())

    @property
    def notices(self) -> int:
        """Return the notice count."""
        with self._lock:
            return self._count_severity("notice")

    @property
    def warnings(self) -> int:
        """Return the warning count."""
        with self._lock:
            return self._count_severity("warn")

    @property
    def fatals(self) -> int:
        """Return the fatal count."""
        with self._lock:
            return self._count_severity("fatal")

    def _count_severity(self, prefix: str) -> int:
        """Count matching severities while the caller holds `_lock`."""
        return sum(count for severity, count in self._severity_counts.items() if severity.startswith(prefix))
