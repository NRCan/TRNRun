"""Manage simulations through one TRNRun Queue process.

The queue owns the concurrency: it runs simulations on its own worker threads
and reports on them through one stdout stream. This manager is its synchronous
client. Nothing runs in the background here, so simulation state advances only
while a call into the manager is reading that stream: `add` reads until its own
request is picked up, and `wait` and `follow` read until the accepted runs
finish. Long pauses between calls can fill the stdout pipe and stall the queue.
Use this manager from one thread; it has no background reader or synchronization.
Premature queue EOF raises an error; no recovery or simulation outcomes are
synthesized.
Display errors propagate to the caller. Use each manager for one context only;
repeated shutdown and operations after shutdown are not supported.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Iterator
from dataclasses import replace
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
        self._queue_eof: bool = False

        self._process: QueueProcess = QueueProcess(trnrunq_path, max_concurrent)

    @property
    def simulations(self) -> list[Simulation]:
        """Return queue-accepted simulations in acceptance order."""
        return list(self._simulations)

    def add(self, deck_file: str | Path, config: SimulationConfig) -> Simulation:
        """Submit one simulation, blocking until a worker picks it up before launch."""
        deck_path = Path(deck_file).absolute()
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        config = replace(config)
        config.validate()

        simulation = Simulation(deck_path, config, self._next_id)
        self._next_id += 1
        self._process.send(
            {
                "runID": str(simulation.id),
                "deckFile": str(deck_path),
                "runnerPath": str(config.trnrun_path),
                "runnerArgs": config.to_cli_args(),
            },
        )
        self._active[str(simulation.id)] = simulation

        while not simulation.is_accepted:
            _ = self._read_next_update()
        return simulation

    def follow(self) -> Iterator[Simulation]:
        """Yield updated simulations until no runs remain.

        Each simulation is yielded after the event that changed it has been
        applied, which makes this the point to render or record progress.
        Updates already consumed by other manager calls are not replayed.
        Raises `RuntimeError` if queue stdout closes with outstanding runs.
        """
        while self._active:
            simulation = self._read_next_update()
            if simulation is None:
                return
            yield simulation

    def wait(self, simulation: Simulation | None = None) -> None:
        """Read queue output until one simulation or all simulations finish.

        With no argument, wait for every accepted run. Otherwise, return when
        the selected simulation receives queue completion, processing other
        runs' events along the way. An already-finished simulation returns
        immediately. The simulation must belong to this manager, or a
        `ValueError` is raised.

        This blocks without a timeout and raises `RuntimeError` on premature
        queue EOF. Inspect the simulations for runner-reported outcomes.
        Leaving the manager context still waits for all remaining runs.
        """
        if simulation is not None:
            if not any(simulation is owned for owned in self._simulations):
                raise ValueError("Simulation does not belong to this manager")
            if simulation.is_finished:
                return

        for _ in self.follow():
            if simulation is not None and simulation.is_finished:
                return

    @property
    def succeeded(self) -> list[Simulation]:
        """Return simulations that completed successfully."""
        return [simulation for simulation in self._simulations if simulation.succeeded]

    @property
    def failed(self) -> list[Simulation]:
        """Return simulations that completed without succeeding."""
        return [simulation for simulation in self._simulations if simulation.is_finished and not simulation.succeeded]

    def shutdown(self) -> None:
        """Drain and reap the queue, reporting EOF or exit failures; call only once."""
        self._process.close()
        exit_code = 0
        try:
            while not self._queue_eof and self._read_next_update() is not None:
                pass
        finally:
            # Only wait after EOF: waiting with undrained stdout can deadlock.
            if self._queue_eof:
                exit_code = self._process.wait()
        # Preserve an already reported premature-EOF error during context cleanup.
        if exit_code and not self._active:
            raise RuntimeError(f"TRNRun queue exited with code {exit_code}; see queue stderr for details")

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
        """Read and apply an update; EOF is normal only with no outstanding runs."""
        while True:
            line = self._process.read_line()
            if line is None:
                self._queue_eof = True
                if self._active:
                    raise RuntimeError(
                        f"TRNRun queue closed before accepting or completing run IDs: {', '.join(self._active)}",
                    )
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
