"""Manage simulations through one TRNRun Queue process.

The queue owns the concurrency: it runs simulations on its own worker threads
and reports on them through one stdout stream. This manager is its synchronous
client. Nothing runs in the background here, so simulation state advances only
while a call into the manager is reading that stream: `add` reads until its own
request is picked up, and `wait` and `follow` read until the accepted runs
finish. Long pauses between calls can fill the stdout pipe and stall the queue.
Use this manager from one thread; it has no background reader or synchronization.
The queue is assumed to stay alive until shutdown; crash recovery is not supported.
Display errors propagate to the caller. Use each manager for one context only;
repeated shutdown and operations after shutdown are not supported.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Iterator
from pathlib import Path
from types import TracebackType
from typing import Final, Self

from trnrun.config import BUNDLED_TRNRUNQ_PATH, SimulationConfig
from trnrun.display import Display, NullDisplay
from trnrun.events import EventParseError, QueueEvent, parse_stream_line
from trnrun.process import QueueProcess
from trnrun.simulation import Simulation

logger = logging.getLogger(__name__)

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)


class SimulationManager:
    """Submit and monitor simulations through one `trnrunq.exe` process."""

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        refresh_interval: float = 1.0,
        *,
        trnrunq_path: str | Path = BUNDLED_TRNRUNQ_PATH,
    ) -> None:
        """Start the queue process."""
        self._display: Display | NullDisplay = (
            Display(refresh_interval=refresh_interval) if refresh_interval > 0 else NullDisplay()
        )
        self._simulations: list[Simulation] = []
        self._active: dict[str, Simulation] = {}
        self._next_id: int = 1

        self._process: QueueProcess = QueueProcess(trnrunq_path, max_concurrent)

    @property
    def simulations(self) -> list[Simulation]:
        """Return queue-accepted simulations in acceptance order."""
        return list(self._simulations)

    def add(self, deck_file: str | Path, config: SimulationConfig) -> Simulation:
        """Submit one simulation, blocking until a worker picks it up before launch."""
        deck_path = Path(deck_file)
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        config.validate()

        simulation = Simulation(deck_path, config, self._next_id)
        self._next_id += 1
        self._process.send(
            {
                "runId": str(simulation.id),
                "deckFile": str(deck_path),
                "runnerPath": str(config.trnrun_path),
                "runnerArgs": config.to_cli_args(),
            },
        )
        self._active[str(simulation.id)] = simulation

        while not simulation.is_accepted:
            if self._read_next_update() is None:
                raise RuntimeError(f"TRNRun queue closed before accepting simulation {simulation.id}")
        return simulation

    def follow(self) -> Iterator[Simulation]:
        """Yield each simulation as queue output updates it, until every run finishes.

        Each simulation is yielded after the event that changed it has been
        applied, which makes this the point to render or record progress.
        Updates already consumed by other manager calls are not replayed.
        """
        while self._active:
            simulation = self._read_next_update()
            if simulation is None:
                return
            yield simulation

    def wait(self) -> None:
        """Read queue output until all simulations finish or the queue exits.

        This blocks without a timeout. Inspect the simulations for outcomes.
        """
        for _ in self.follow():
            pass

    @property
    def succeeded(self) -> list[Simulation]:
        """Return simulations that completed successfully."""
        return [simulation for simulation in self._simulations if simulation.succeeded]

    @property
    def failed(self) -> list[Simulation]:
        """Return simulations that completed without succeeding."""
        return [simulation for simulation in self._simulations if simulation.is_finished and not simulation.succeeded]

    def shutdown(self) -> None:
        """Close queue input and drain accepted simulations; call only once."""
        self._process.close()
        while self._read_next_update() is not None:
            pass
        _ = self._process.wait()

    def __enter__(self) -> Self:
        """Enter the manager context."""
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Drain the queue when leaving the manager context."""
        self.shutdown()

    def _read_next_update(self) -> Simulation | None:
        """Read and apply the next routable update, or return None at EOF."""
        while True:
            line = self._process.read_line()
            if line is None:
                return None

            try:
                parsed = parse_stream_line(line)
            except EventParseError:
                logger.debug("dropped malformed queue line: %r", line, exc_info=True)
                continue

            if parsed is None:
                continue

            run_id, event = parsed
            simulation = self._active.get(run_id)
            if simulation is None:
                continue

            match event:
                case QueueEvent(event="ACCEPTED"):
                    if simulation.is_accepted:
                        continue
                    simulation.mark_accepted()
                    self._simulations.append(simulation)
                    self._display.simulation_started(simulation)
                case QueueEvent(event="COMPLETED"):
                    del self._active[run_id]
                    simulation.mark_completed(event)
                    self._display.simulation_finished(simulation)
                case QueueEvent():
                    continue
                case _:
                    simulation.apply_event(event)
                    self._display.refresh()

            return simulation
