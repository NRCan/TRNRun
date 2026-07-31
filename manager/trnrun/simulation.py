"""Python-side handle for a single TRNRun process.

Provides ``Simulation``, which spawns one TRNRun execution and mirrors its
stdout event stream (status, progress, config, and log events) behind a
thread-safe snapshot.
"""

from __future__ import annotations

import logging
import subprocess
import threading
from collections import Counter, deque
from dataclasses import dataclass
from pathlib import Path
from typing import IO

from trnrun.config import SimulationConfig
from trnrun.events import (
    ConfigEvent,
    LogEvent,
    ProgressEvent,
    StatusEvent,
    TrnRunEvent,
    stream_events,
)
from trnrun.process import spawn_process

logger = logging.getLogger(__name__)


# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
DEFAULT_MAX_LOG_EVENTS = 5000
EXIT_CODE_UNKNOWN = -1024


# -----------------------------------------------------------------
# Snapshot
# -----------------------------------------------------------------
@dataclass(frozen=True)
class SimulationSnapshot:
    """Consistent view of a simulation, read under a single lock.

    Every field is captured in one critical section, so a consumer can
    never mix state from either side of an event.

    Attributes
    ----------
    id : int
        Identifier assigned by the manager.
    deck_path : str
        Path to the deck (`.dck`) file passed to TRNRun.
    status : StatusEvent | None
        Latest status event, or `None` if none has been received.
    progress : ProgressEvent | None
        Latest progress event, or `None` if none has been received.
    config_event : ConfigEvent | None
        Latest config event, or `None` if none has been received.
    notices : int
        Number of notice-severity log events observed.
    warnings : int
        Number of warning-severity log events observed.
    fatals : int
        Number of fatal-severity log events observed.
    log_count : int
        Total number of log events observed.
    exit_code : int | None
        Process exit code, or ``None`` if the run has not finished.
        ``EXIT_CODE_UNKNOWN`` means the run finished but no usable code
        was obtained.
    error : str | None
        Error message if the run failed, otherwise `None`.
    cancelled : bool
        Whether termination was requested via `Simulation.cancel`.
    """

    id: int | None
    deck_path: Path
    status: StatusEvent | None
    progress: ProgressEvent | None
    config_event: ConfigEvent | None
    notices: int
    warnings: int
    fatals: int
    log_count: int
    exit_code: int | None
    error: str | None
    cancelled: bool


# -----------------------------------------------------------------
# Simulation
# -----------------------------------------------------------------
class Simulation:
    """Python representation of one TRNRun execution.

    TRNRun owns simulation state. This class only mirrors the latest
    events received on stdout, plus local process bookkeeping (PID,
    exit code, cancellation).

    Parameters
    ----------
    sim_id : int
        Identifier assigned by the manager. Stored as `id`.
    deck_path : str
        Path to the deck (`.dck`) file passed to TRNRun.
    config : SimulationConfig
        Runtime configuration forwarded to `spawn_process`.
    max_log_events : int, optional
        Maximum number of log events kept in the rolling log window.
    """

    def __init__(
        self,
        deck_path: str | Path,
        config: SimulationConfig,
        sim_id: int | None = None,
        max_log_events: int = DEFAULT_MAX_LOG_EVENTS,
    ) -> None:
        """Initialize the simulation."""
        self.id: int | None = sim_id
        self.deck_path: Path = Path(deck_path)
        self.config: SimulationConfig = config

        self._lock: threading.Lock = threading.Lock()

        self._process: subprocess.Popen[str] | None = None
        self._started: bool = False
        self._cancel_requested: bool = False

        self._status: StatusEvent | None = None
        self._progress: ProgressEvent | None = None
        self._config_event: ConfigEvent | None = None

        self._logs: deque[LogEvent] = deque(maxlen=max_log_events)
        self._severity_counts: Counter[str] = Counter()

        self._exit_code: int | None = None
        self._error: str | None = None

    # -----------------------------------------------------------------
    # Lifecycle
    # -----------------------------------------------------------------
    def run(self) -> None:
        """Spawn TRNRun and consume its stdout until the process exits."""
        with self._lock:
            if self._started:
                raise RuntimeError(f"Simulation {self.id} was already started")

            self._started = True

            if self._cancel_requested:
                return

        code: int | None = None
        error: str | None = None

        try:
            with spawn_process(self.deck_path, self.config) as process:
                try:
                    with self._lock:
                        self._process = process
                        cancel_requested = self._cancel_requested

                    if cancel_requested:
                        process.terminate()

                    stdout = self._get_stdout(process)
                    for event in stream_events(stdout, skip_invalid=True):
                        self.apply(event)

                    code = process.wait()

                except Exception:
                    code = self._reap(process)
                    raise

        except Exception as exc:
            logger.exception("Simulation %s failed", self.id)
            error = str(exc)

        finally:
            with self._lock:
                self._error = error
                self._exit_code = EXIT_CODE_UNKNOWN if code is None else code

    def cancel(self) -> None:
        """Request termination of the TRNRun process."""
        with self._lock:
            self._cancel_requested = True
            process = self._process

            if not self._started:
                self._error = "cancelled before start"
                self._exit_code = EXIT_CODE_UNKNOWN

        if process is not None and process.poll() is None:
            process.terminate()

    # -----------------------------------------------------------------
    # Event Ingestion
    # -----------------------------------------------------------------
    def apply(self, event: TrnRunEvent) -> None:
        """Fold one parsed TRNRun event into the simulation snapshot."""
        with self._lock:
            match event:
                case StatusEvent():
                    self._status = event
                case ConfigEvent():
                    self._config_event = event
                case ProgressEvent():
                    self._progress = event
                case LogEvent():
                    self._logs.append(event)
                    self._severity_counts[event.severity.lower()] += 1

    # -----------------------------------------------------------------
    # State Access
    # -----------------------------------------------------------------
    def snapshot(self) -> SimulationSnapshot:
        """Return a consistent view of every field a consumer usually needs."""
        with self._lock:
            return SimulationSnapshot(
                id=self.id,
                deck_path=self.deck_path,
                status=self._status,
                progress=self._progress,
                config_event=self._config_event,
                notices=self._count_severity("notice"),
                warnings=self._count_severity("warn"),
                fatals=self._count_severity("fatal"),
                log_count=sum(self._severity_counts.values()),
                exit_code=self._exit_code,
                error=self._error,
                cancelled=self._cancel_requested,
            )

    @property
    def status(self) -> StatusEvent | None:
        """Latest status event."""
        with self._lock:
            return self._status

    @property
    def progress(self) -> ProgressEvent | None:
        """Latest progress event."""
        with self._lock:
            return self._progress

    @property
    def config_event(self) -> ConfigEvent | None:
        """Latest config event."""
        with self._lock:
            return self._config_event

    @property
    def logs(self) -> list[LogEvent]:
        """Snapshot of retained logs."""
        with self._lock:
            return list(self._logs)

    @property
    def exit_code(self) -> int | None:
        """Process exit code."""
        with self._lock:
            return self._exit_code

    @property
    def error(self) -> str | None:
        """Error message."""
        with self._lock:
            return self._error

    @property
    def cancelled(self) -> bool:
        """Whether termination was requested via :meth:`cancel`."""
        with self._lock:
            return self._cancel_requested

    @property
    def pid(self) -> int | None:
        """TRNRun PID."""
        with self._lock:
            return self._process.pid if self._process else None

    @property
    def is_running(self) -> bool:
        """Whether the local process is alive."""
        with self._lock:
            process = self._process

        return process is not None and process.poll() is None

    @property
    def is_finished(self) -> bool:
        """Whether an exit code has been recorded."""
        return self.exit_code is not None

    @property
    def succeeded(self) -> bool:
        """Whether the simulation completed successfully."""
        with self._lock:
            return (
                self._exit_code == 0
                and self._error is None
                and not self._cancel_requested
                and self._count_severity("fatal") == 0
            )

    @property
    def log_count(self) -> int:
        """Total log count."""
        with self._lock:
            return sum(self._severity_counts.values())

    @property
    def notices(self) -> int:
        """Notice count."""
        with self._lock:
            return self._count_severity("notice")

    @property
    def warnings(self) -> int:
        """Warning count."""
        with self._lock:
            return self._count_severity("warn")

    @property
    def fatals(self) -> int:
        """Fatal count."""
        with self._lock:
            return self._count_severity("fatal")

    # -----------------------------------------------------------------
    # Internal Helpers
    # -----------------------------------------------------------------
    def _count_severity(self, prefix: str) -> int:
        """Count severity events whose name starts with `prefix` (caller holds `_lock`)."""
        return sum(count for severity, count in self._severity_counts.items() if severity.startswith(prefix))

    @staticmethod
    def _get_stdout(process: subprocess.Popen[str]) -> IO[str]:
        """Return TRNRun stdout or raise if unavailable."""
        if process.stdout is None:
            raise RuntimeError("TRNRun stdout unavailable")
        return process.stdout

    @staticmethod
    def _reap(process: subprocess.Popen[str]) -> int:
        """Terminate a failed process and return its exit code."""
        if process.poll() is None:
            process.terminate()
            try:
                return process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()

        return process.wait()
