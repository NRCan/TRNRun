"""Simulation management through one TRNRun Queue process."""

from __future__ import annotations

import os
from dataclasses import replace
from pathlib import Path
from threading import Condition
from types import TracebackType
from typing import Final, Self

from trnrun.config import BUNDLED_TRNRUNQ_PATH, SimulationConfig
from trnrun.display import DisplayCallback, create_display
from trnrun.events import EventParseError, TrnRunEvent, parse_stream_line
from trnrun.process import QueueProcess
from trnrun.simulation import Simulation

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)


class SimulationManager:
    """Submit and monitor simulations through one TRNRun Queue process.

    Queue output is consumed on the ``QueueProcess`` reader thread. Display
    callbacks must return promptly and must not call blocking manager methods.
    GUI applications can inspect ``Simulation.snapshot()`` from their UI thread.
    Shutdown is owner-controlled and must not be concurrent or reentrant.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        refresh_interval: float = 1.0,
        *,
        trnrunq_path: str | Path = BUNDLED_TRNRUNQ_PATH,
        display: DisplayCallback | None = None,
    ) -> None:
        self._condition: Condition = Condition()
        self._simulations: dict[str, Simulation] = {}
        self._next_id: int = 1
        self._closed: bool = False
        self._cleanup_complete: bool = False
        self._reader_stopped: bool = False

        self._display: DisplayCallback = display if display is not None else create_display(refresh_interval)
        self._process: QueueProcess = QueueProcess(trnrunq_path, max_concurrent, self._on_queue_output, self._on_queue_exit)

    @property
    def submitted(self) -> list[Simulation]:
        """Return a copy of all tracked handles in submission order.

        Includes pending, running, and completed simulations. Failed sends
        are removed unless the queue already accepted the simulation.
        """
        with self._condition:
            return list(self._simulations.values())

    @property
    def simulations(self) -> list[Simulation]:
        """Return accepted simulations in submission order."""
        with self._condition:
            return [simulation for simulation in self._simulations.values() if simulation.is_accepted]

    @property
    def active(self) -> list[Simulation]:
        """Return unfinished simulations, including pending submissions."""
        with self._condition:
            return [simulation for simulation in self._simulations.values() if not simulation.is_finished]

    @property
    def succeeded(self) -> list[Simulation]:
        """Return simulations that completed successfully."""
        return [simulation for simulation in self.simulations if simulation.succeeded]

    @property
    def failed(self) -> list[Simulation]:
        """Return simulations that finished without succeeding."""
        return [simulation for simulation in self.simulations if simulation.is_finished and not simulation.succeeded]


    def add(self, deck_file: str | Path, config: SimulationConfig, *, blocking: bool = True) -> Simulation:
        """Submit a simulation, optionally waiting for queue acceptance."""
        deck_path: Path = Path(deck_file).absolute()
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        config = replace(config)
        config.validate()
        runner_args: list[str] = config.to_cli_args()

        with self._condition:
            if self._closed:
                raise RuntimeError("SimulationManager is closed")
            if self._reader_stopped:
                raise RuntimeError("TRNRun queue output stopped")
            simulation: Simulation = Simulation(deck_path, config, self._next_id)
            self._next_id += 1
            run_id: str = str(simulation.id)
            self._simulations[run_id] = simulation

        try:
            # A full stdin pipe must not prevent the reader from acquiring the condition.
            self._process.send(
                {
                    "runId": run_id,
                    "deckFile": str(deck_path),
                    "runnerPath": str(config.trnrun_path),
                    "runnerArgs": runner_args,
                },
            )
        except Exception:
            with self._condition:
                if not simulation.is_accepted:
                    _ = self._simulations.pop(run_id, None)
                self._condition.notify_all()
            raise

        if blocking:
            with self._condition:
                _ = self._condition.wait_for(lambda: simulation.is_accepted or self._closed or self._reader_stopped)
                if self._closed:
                    raise RuntimeError("SimulationManager is closed")
                if self._reader_stopped and not simulation.is_accepted:
                    raise RuntimeError("TRNRun queue output stopped before acceptance")
        return simulation

    def wait(self, simulation: Simulation | None = None) -> None:
        """Wait for one owned simulation, or all outstanding submissions."""
        with self._condition:
            if self._closed:
                raise RuntimeError("SimulationManager is closed")
            if simulation is not None and self._simulations.get(str(simulation.id)) is not simulation:
                raise ValueError("Simulation does not belong to this manager")
            def finished() -> bool:
                return simulation.is_finished if simulation is not None else all(
                    item.is_finished for item in self._simulations.values()
                )

            _ = self._condition.wait_for(lambda: finished() or self._closed or self._reader_stopped)
            if self._closed:
                raise RuntimeError("SimulationManager is closed")
            if self._reader_stopped and not finished():
                raise RuntimeError("TRNRun queue output stopped before completion")

    def shutdown(self) -> None:
        """Stop the queue and close the display, retrying incomplete cleanup."""
        with self._condition:
            if self._cleanup_complete:
                return
            self._closed = True
            self._condition.notify_all()

        self._process.shutdown()
        self._display.close()
        self._cleanup_complete = True

    def __enter__(self) -> Self:
        """Enter the manager before shutdown."""
        if self._closed:
            raise RuntimeError("SimulationManager is closed")
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Release the queue and display when leaving the context."""
        self.shutdown()

    def _on_queue_exit(self) -> None:
        """Wake blocked submissions and observers when stdout closes."""
        with self._condition:
            self._reader_stopped = True
            self._condition.notify_all()

    def _on_queue_output(self, line: str) -> None:
        """Apply one queue output line to its simulation."""
        try:
            parsed: tuple[str, TrnRunEvent] | None = parse_stream_line(line)
        except EventParseError:
            return
        if parsed is None:
            return

        run_id, event = parsed
        with self._condition:
            if self._closed:
                return
            simulation: Simulation | None = self._simulations.get(run_id)
            if simulation is None:
                return
            accepted_before: bool = simulation.is_accepted
            if not simulation.apply_event(event):
                return

            started: bool = simulation.is_accepted and not accepted_before
            finished: bool = simulation.is_finished
            self._condition.notify_all()

        try:
            if started:
                self._display.simulation_started(simulation)
            elif finished:
                self._display.simulation_finished(simulation)
            else:
                self._display.refresh()
        except Exception:  # noqa: BLE001 - display failures must not stop the queue reader
            pass
