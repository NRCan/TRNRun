"""State for one simulation submitted through TRNRun Queue.

A simulation is mutated only while its manager is pumping queue output, on the
caller's own thread, so none of this state is synchronized. Runner outcomes and
queue completion metadata are retained without synthesizing events.
"""

from __future__ import annotations

from collections import Counter, deque
from pathlib import Path
from typing import Final

from trnrun.config import SimulationConfig
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    QueueEvent,
    SettingEvent,
    StatusEvent,
    TrnRunEvent,
    is_terminal_status,
)

DEFAULT_MAX_LOG_EVENTS: Final[int] = 5000


class Simulation:
    """Event state for one queued simulation."""

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

        self._accepted: bool = False
        self._finished: bool = False
        self._completion_event: QueueEvent | None = None
        self._status: StatusEvent | None = None
        self._progress: ProgressEvent | None = None
        self._config_event: ConfigEvent | None = None
        self._setting_event: SettingEvent | None = None
        self._logs: deque[LogEvent] = deque(maxlen=max_log_events)
        self._severity_counts: Counter[str] = Counter()

    def apply_event(self, event: TrnRunEvent) -> None:
        """Fold one runner event into the simulation state.

        Queue lifecycle events share the ``TrnRunEvent`` union but carry no
        runner state; the manager routes them to ``mark_accepted`` and
        ``mark_completed`` instead.
        """
        if self._finished:
            return

        match event:
            case StatusEvent():
                self._status = event
            case ConfigEvent():
                self._config_event = event
            case SettingEvent():
                self._setting_event = event
            case ProgressEvent():
                self._progress = event
            case LogEvent():
                self._logs.append(event)
                self._severity_counts[event.severity.lower()] += 1
            case QueueEvent():
                return

    def mark_accepted(self) -> None:
        """Record that a queue worker picked the simulation up."""
        self._accepted = True

    def mark_completed(self, event: QueueEvent) -> None:
        """Retain the queue's completion event and finish this run.

        Completion does not determine the outcome: success still requires
        the runner's own terminal ``STATUS/DONE`` event.
        """
        if self._finished:
            return
        self._completion_event = event
        self._finished = True

    @property
    def completion_event(self) -> QueueEvent | None:
        """Return QUEUE/COMPLETED metadata, or None if not received.

        The event's exit_code is None when the runner could not be launched.
        A missing event instead means the run has not been marked finished.
        """
        return self._completion_event

    @property
    def status(self) -> StatusEvent | None:
        """Return the latest status event."""
        return self._status

    @property
    def progress(self) -> ProgressEvent | None:
        """Return the latest progress event."""
        return self._progress

    @property
    def config_event(self) -> ConfigEvent | None:
        """Return the latest simulation configuration event."""
        return self._config_event

    @property
    def setting_event(self) -> SettingEvent | None:
        """Return the latest runner setting event."""
        return self._setting_event

    @property
    def logs(self) -> list[LogEvent]:
        """Return retained log events."""
        return list(self._logs)

    @property
    def is_running(self) -> bool:
        """Return whether the simulation is waiting or running."""
        return not self._finished

    @property
    def is_accepted(self) -> bool:
        """Return whether a queue worker picked the simulation up."""
        return self._accepted

    @property
    def is_finished(self) -> bool:
        """Return whether the queue reported completion for this run."""
        return self._finished

    @property
    def has_terminal_status(self) -> bool:
        """Return whether the runner reported a canonical terminal status."""
        return self._status is not None and is_terminal_status(self._status.status)

    @property
    def succeeded(self) -> bool:
        """Return whether a completed run has the terminal status `DONE`."""
        return self._finished and self._status is not None and self._status.status == "DONE"

    @property
    def log_count(self) -> int:
        """Return the total number of log events."""
        return sum(self._severity_counts.values())

    @property
    def notices(self) -> int:
        """Return the notice count."""
        return self._count_severity("notice")

    @property
    def warnings(self) -> int:
        """Return the warning count."""
        return self._count_severity("warn")

    @property
    def fatals(self) -> int:
        """Return the fatal count."""
        return self._count_severity("fatal")

    def _count_severity(self, prefix: str) -> int:
        """Count matching severities."""
        return sum(count for severity, count in self._severity_counts.items() if severity.startswith(prefix))
