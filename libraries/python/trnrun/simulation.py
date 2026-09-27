"""State for one simulation submitted through TRNRun Queue.

State is folded on the manager's reader thread and read by whatever thread the
caller polls from, so every field is guarded by one re-entrant lock. Each
property takes the lock on its own, which makes any single read coherent.

Reading *several* fields coherently requires holding the lock across all of
them, which is why `lock` is public::

    with simulation.lock:
        percent = simulation.percent
        status = simulation.status

Hold it only long enough to copy values out. The manager's reader thread takes
the same lock to apply each event, and a caller that holds it while doing slow
work stops queue stdout from draining, which stalls every concurrent run.
"""

from __future__ import annotations

import threading
from collections import deque
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
    """Event state for one queued simulation.

    Parameters
    ----------
    deck_path : str or Path
        Deck submitted for this run.
    config : SimulationConfig
        Configuration the run was submitted with.
    sim_id : int
        Manager-assigned identifier, used as the queue `runID`.
    max_log_events : int
        Bound on retained log history, not on counters; 0 retains no logs.
    """

    def __init__(
        self,
        deck_path: str | Path,
        config: SimulationConfig,
        sim_id: int,
        max_log_events: int = DEFAULT_MAX_LOG_EVENTS,
    ) -> None:
        """Initialize a pending simulation."""
        # Set once at construction and never mutated, so these need no lock.
        self.id: int = sim_id
        self.deck_path: Path = Path(deck_path)
        self.config: SimulationConfig = config

        # Re-entrant so a caller holding `lock` can still use the properties,
        # each of which takes the lock itself.
        self._lock: threading.RLock = threading.RLock()

        self._accepted: bool = False
        self._status: StatusEvent | None = None
        self._progress: ProgressEvent | None = None
        self._config_event: ConfigEvent | None = None
        self._setting_event: SettingEvent | None = None
        self._completion_event: QueueEvent | None = None
        self._logs: deque[LogEvent] = deque(maxlen=max_log_events)
        self._log_count: int = 0
        self._notices: int = 0
        self._warnings: int = 0
        self._fatals: int = 0

        self._accepted_event: threading.Event = threading.Event()
        self._finished_event: threading.Event = threading.Event()

    # -----------------------------------------------------------------
    # Coherent multi-field reads
    # -----------------------------------------------------------------
    @property
    def lock(self) -> threading.RLock:
        """Return the lock guarding this simulation's state.

        Hold it to read several fields as one consistent view; individual
        properties take it themselves, so two reads in a row without it may
        describe different instants. Release it promptly: the manager's reader
        thread needs it to apply events, and blocking that thread stalls queue
        output for every concurrent run.
        """
        return self._lock

    # -----------------------------------------------------------------
    # Reading
    # -----------------------------------------------------------------
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
    def completion_event(self) -> QueueEvent | None:
        """Return QUEUE/COMPLETED metadata, or None if not received.

        The event's exit_code is None when the runner could not be launched.
        A missing event instead means the run has not been marked finished.
        """
        with self._lock:
            return self._completion_event

    @property
    def percent(self) -> float:
        """Return run completion from 0 to 1, or 0.0 before the first progress event."""
        with self._lock:
            return self._progress.percent if self._progress is not None else 0.0

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
    def is_running(self) -> bool:
        """Return whether the simulation is waiting or running."""
        return not self.is_finished

    @property
    def has_terminal_status(self) -> bool:
        """Return whether the runner reported a canonical terminal status."""
        with self._lock:
            return self._status is not None and is_terminal_status(self._status.status)

    @property
    def succeeded(self) -> bool:
        """Return whether a completed run has the terminal status `DONE`."""
        with self._lock:
            return self._completion_event is not None and self._status is not None and self._status.status == "DONE"

    @property
    def logs(self) -> list[LogEvent]:
        """Return a copy of retained log events, oldest first."""
        with self._lock:
            return list(self._logs)

    @property
    def log_count(self) -> int:
        """Return the total received log count, including evicted entries."""
        with self._lock:
            return self._log_count

    @property
    def notices(self) -> int:
        """Return the notice count."""
        with self._lock:
            return self._notices

    @property
    def warnings(self) -> int:
        """Return the warning count."""
        with self._lock:
            return self._warnings

    @property
    def fatals(self) -> int:
        """Return the fatal count."""
        with self._lock:
            return self._fatals

    # -----------------------------------------------------------------
    # Blocking
    # -----------------------------------------------------------------
    def wait(self, timeout: float | None = None) -> bool:
        """Block until this run finishes, returning False if `timeout` elapsed first.

        Also returns when the manager abandons the run, so a caller is never
        stranded by a queue that closed early. Check `is_finished` to tell a
        completed run from an abandoned one.
        """
        return self._finished_event.wait(timeout)

    def wait_accepted(self, timeout: float | None = None) -> bool:
        """Block until a queue worker accepts this run, or it is abandoned."""
        return self._accepted_event.wait(timeout)

    # -----------------------------------------------------------------
    # Writing: manager reader thread only
    # -----------------------------------------------------------------
    def apply_event(self, event: TrnRunEvent) -> bool:
        """Apply one runner or queue event, returning whether it was applied.

        Duplicate acceptance, unrecognized queue events, and all events after
        completion return False without changing state. Queue completion
        records metadata; success still depends on the runner's terminal
        status.
        """
        with self._lock:
            if self._completion_event is not None:
                return False

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
                    self._record_log(event)
                case QueueEvent(event="ACCEPTED") if not self._accepted:
                    self._accepted = True
                case QueueEvent(event="COMPLETED"):
                    self._completion_event = event
                case QueueEvent():
                    return False

            accepted = self._accepted
            finished = self._completion_event is not None

        # Signal outside the lock so a woken waiter does not immediately queue
        # behind this thread to read the state it was waiting for.
        if accepted:
            self._accepted_event.set()
        if finished:
            self._finished_event.set()
        return True

    def abandon(self) -> None:
        """Release waiters for a run the queue will never complete.

        State is left unfinished so an abandoned run is never mistaken for a
        successful one; only the waiters are released.
        """
        self._accepted_event.set()
        self._finished_event.set()

    def _record_log(self, event: LogEvent) -> None:
        """Retain a log event and advance its severity counter.

        The caller already holds the lock.
        """
        self._logs.append(event)
        self._log_count += 1

        severity = event.severity.lower()
        if severity == "notice":
            self._notices += 1
        elif severity == "warning":
            self._warnings += 1
        elif severity == "fatal":
            self._fatals += 1
