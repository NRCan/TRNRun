"""Synchronous simulation management through one TRNRun Queue process."""

from __future__ import annotations

import logging
import os
from collections.abc import Iterator
from dataclasses import replace
from pathlib import Path
from types import TracebackType
from typing import Final, Self

from trnrun.config import BUNDLED_TRNRUNQ_PATH, SimulationConfig
from trnrun.display import DisplayCallback, create_display
from trnrun.events import EventParseError, TrnRunEvent, parse_stream_line
from trnrun.process import QueueProcess
from trnrun.simulation import Simulation

logger = logging.getLogger(__name__)

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)


class SimulationManager:
    """Submit and monitor simulations through one `trnrunq.exe` process.

    Parameters
    ----------
    max_concurrent : int
        Maximum simultaneous runners. Defaults to the logical CPU count minus
        one, with a minimum of one.
    refresh_interval : float
        Minimum seconds between display refreshes. Nonpositive values disable
        the display.
    trnrunq_path : str or Path
        Queue executable to start. Defaults to the bundled `trnrunq.exe`.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        refresh_interval: float = 1.0,
        *,
        trnrunq_path: str | Path = BUNDLED_TRNRUNQ_PATH,
    ) -> None:
        """Start the queue process."""
        self._display: DisplayCallback = create_display(refresh_interval)
        self._simulations: list[Simulation] = []
        self._active: dict[str, Simulation] = {}
        self._next_id: int = 1

        self._closed: bool = False

        self._process: QueueProcess = QueueProcess(trnrunq_path, max_concurrent)

    @property
    def simulations(self) -> list[Simulation]:
        """Return queue-accepted simulations in acceptance order."""
        return list(self._simulations)

    @property
    def succeeded(self) -> list[Simulation]:
        """Return simulations that completed successfully."""
        return [simulation for simulation in self._simulations if simulation.succeeded]

    @property
    def failed(self) -> list[Simulation]:
        """Return simulations that completed without succeeding."""
        return [simulation for simulation in self._simulations if simulation.is_finished and not simulation.succeeded]

    def add(self, deck_file: str | Path, config: SimulationConfig) -> Simulation:
        """Submit a simulation and wait for acceptance; reject calls after shutdown starts."""
        if self._closed:
            raise RuntimeError("Cannot add simulations after shutdown has started")

        deck_path = Path(deck_file).absolute()
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        config = replace(config)
        config.validate()

        simulation = Simulation(deck_path, config, self._next_id)
        self._next_id += 1
        run_id = str(simulation.id)
        self._process.send(
            {
                "runID": run_id,
                "deckFile": str(deck_path),
                "runnerPath": str(config.trnrun_path),
                "runnerArgs": config.to_cli_args(),
            },
        )
        self._active[run_id] = simulation

        while not simulation.is_accepted:
            _ = self._read_next_update()
        return simulation

    def follow(self, simulation: Simulation | None = None) -> Iterator[Simulation]:
        """Yield updates for one simulation, or all simulations when omitted.

        Every queue event is still processed so all simulations remain current,
        but when `simulation` is provided only that run is yielded and iteration
        ends when it completes. Updates already consumed by other manager calls
        are not replayed. The selected simulation must belong to this manager,
        or a `ValueError` is raised. Raises `RuntimeError` if queue stdout closes
        with outstanding runs, or if shutdown has started.
        """
        if self._closed:
            raise RuntimeError("Cannot follow simulations after shutdown has started")

        if simulation is not None:
            if not any(simulation is owned for owned in self._simulations):
                raise ValueError("Simulation does not belong to this manager")
            if simulation.is_finished:
                return

        while self._active:
            if self._closed:
                raise RuntimeError("Cannot follow simulations after shutdown has started")
            updated = self._read_next_update()
            if simulation is None or updated is simulation:
                yield updated
            if simulation is not None and simulation.is_finished:
                return

    def wait(self, simulation: Simulation | None = None) -> None:
        """Block until the selected simulation, or all simulations, finish.

        Processes events through `follow()`, blocking without a timeout and
        propagating its errors. Call before shutdown to collect final results;
        leaving the manager context kills remaining work.
        """
        for _ in self.follow(simulation):
            pass

    def shutdown(self) -> None:
        """Kill and reap the queue without waiting for simulations to finish.

        Call `wait` first to finish runs and collect their results. Shutdown does
        not read events or change simulation state. The manager stays closed if
        cleanup fails or is interrupted; later calls do nothing.
        """
        if self._closed:
            return

        self._closed = True
        try:
            self._process.shutdown()
        finally:
            self._display.close()

    def __enter__(self) -> Self:
        """Enter the manager context before shutdown has started."""
        if self._closed:
            raise RuntimeError("Cannot enter a manager after shutdown has started")
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Kill the queue and release resources when leaving the manager context."""
        self.shutdown()

    def _read_next_update(self) -> Simulation:
        """Read and apply the next update, raising if queue stdout closes first."""
        while (line := self._process.read_line()) is not None:
            try:
                parsed = parse_stream_line(line)
            except EventParseError:
                logger.debug("dropped malformed queue line: %r", line, exc_info=True)
                continue

            if parsed is None:
                continue

            run_id, event = parsed
            simulation = self._dispatch_event(run_id, event)
            if simulation is not None:
                return simulation

        raise RuntimeError(
            f"TRNRun queue closed before accepting or completing run IDs: {', '.join(self._active)}",
        )

    def _dispatch_event(self, run_id: str, event: TrnRunEvent) -> Simulation | None:
        """Apply an event before notifying the display."""
        simulation = self._active.get(run_id)
        if simulation is None:
            return None

        was_accepted = simulation.is_accepted
        if not simulation.apply_event(event):
            return None

        if simulation.is_accepted and not was_accepted:
            self._simulations.append(simulation)
            self._display.simulation_started(simulation)
        elif simulation.is_finished:
            del self._active[run_id]
            self._display.simulation_finished(simulation)
        else:
            self._display.refresh()

        return simulation
