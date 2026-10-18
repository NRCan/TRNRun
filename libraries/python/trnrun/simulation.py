"""State for one simulation submitted through a ``SimulationManager``.

The manager's background thread is the only writer. Each update replaces the
handle's ``info`` as a whole, so one read of ``info`` is a coherent view of
every field, and each property reads it once. The handle also accumulates the
complete log history. To wait for a run, use ``SimulationManager.wait()``.
"""

from pathlib import Path

from trnrun.core.records import LogEvent, ProgressEvent, SimulationInfo, SimulationState, SimulationStatus
from trnrun.core.settings import SimulationSettings


class Simulation:
    """One submitted simulation, kept up to date by its ``SimulationManager``.

    ``run_id``, ``deck_file``, and ``settings`` are what was submitted;
    ``run_id`` is the ID trnrund assigned, the ``run_id`` of its database
    row. ``info`` is the run's latest state from the daemon's database. Each
    other property is the ``info`` field of the same name and type, for the
    everyday ones; read the rest, such as the exit code, timestamps, label,
    and TRNRun's config and settings, from ``info``. Separate reads may
    reflect different updates, so read ``info`` once when several fields must
    agree. ``logs`` holds every log entry received.
    """

    def __init__(self, run_id: int, deck_file: str | Path, settings: SimulationSettings) -> None:
        """Initialize a queued simulation with an empty log history."""
        self.run_id: int = run_id
        self.deck_file: Path = Path(deck_file)
        self.settings: SimulationSettings = settings

        self._info: SimulationInfo = SimulationInfo(run_id, SimulationState.QUEUED, deck_file=self.deck_file)
        self._logs: list[LogEvent] = []

    def _apply(self, info: SimulationInfo | None, logs: list[LogEvent]) -> None:
        """Append new log entries, then replace ``info`` unless it is None; only the manager calls it."""
        # Logs first, so a handle that reads finished already holds its final entries.
        self._logs.extend(logs)
        if info is not None:
            self._info = info

    def __repr__(self) -> str:
        """Summarize the run, such as ``Simulation(run_id=3, deck='model.dck', state=RUNNING, status=RUNNING, 42%)``."""
        info = self._info
        status = None if info.status is None else info.status.value
        percent = "" if info.progress is None else f", {info.progress.percent:.0%}"
        return (
            f"Simulation(run_id={self.run_id}, deck={self.deck_file.name!r}, "
            f"state={info.state.value}, status={status}{percent})"
        )

    @property
    def info(self) -> SimulationInfo:
        """Return the run's latest state, frozen."""
        return self._info

    @property
    def state(self) -> SimulationState:
        """Return the daemon lifecycle: QUEUED, RUNNING or FINISHED."""
        return self._info.state

    @property
    def status(self) -> SimulationStatus | None:
        """Return TRNRun's latest status, such as DONE; its detail is ``info.status_message``."""
        return self._info.status

    @property
    def progress(self) -> ProgressEvent | None:
        """Return the latest progress event."""
        return self._info.progress

    @property
    def notices(self) -> int:
        """Return the notice count."""
        return self._info.notices

    @property
    def warnings(self) -> int:
        """Return the warning count."""
        return self._info.warnings

    @property
    def fatals(self) -> int:
        """Return the fatal count."""
        return self._info.fatals

    @property
    def succeeded(self) -> bool | None:
        """Return whether the run finished with DONE, exit code 0, and no error; None until it finishes."""
        return self._info.succeeded

    @property
    def error(self) -> str | None:
        """Return the daemon execution error, or None."""
        return self._info.error

    @property
    def logs(self) -> list[LogEvent]:
        """Return a copy of all log entries, oldest first."""
        return list(self._logs)

    @property
    def is_finished(self) -> bool:
        """Return whether the daemon finished the run; its logs are then complete."""
        return self._info.is_finished
