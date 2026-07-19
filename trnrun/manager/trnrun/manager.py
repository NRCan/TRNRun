"""Manage concurrent TRNRun simulations.

Provides ``SimulationManager`` to run multiple simulations with a fixed
concurrency limit, monitor their progress, and access completed results.
The manager optionally displays live terminal progress.
"""

from __future__ import annotations

import logging
import os
import threading
from collections.abc import Callable
from concurrent.futures import Future, ThreadPoolExecutor
from concurrent.futures import wait as wait_for_futures
from pathlib import Path
from types import TracebackType
from typing import Final, Self

from trnrun.config import SimulationConfig
from trnrun.display import Display, NullDisplay
from trnrun.simulation import Simulation

logger = logging.getLogger(__name__)


# -----------------------------------------------------------------
# Constants
# -----------------------------------------------------------------
DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)


# -----------------------------------------------------------------
# Slot Strategies
# -----------------------------------------------------------------
class _UnboundedSlots:
    """No-op stand-in for `threading.BoundedSemaphore`.

    Used when `add()` must never block; pending simulations wait in the
    worker pool's internal queue instead of holding the caller.
    """

    def acquire(self) -> bool:
        """Grant a slot immediately."""
        return True

    def release(self) -> None:
        """Do nothing; slots are not tracked."""


# -----------------------------------------------------------------
# Simulation Manager
# -----------------------------------------------------------------
class SimulationManager:
    """Run simulations using a bounded pool of worker threads.

    `add()` starts simulations using a fixed number of worker threads, so no
    more than `max_concurrent` TRNRun processes run at the same time. If all
    workers are busy, `add()` either waits until a worker becomes available
    (`block=True`, the default) or returns immediately and leaves
    the simulation queued until a worker frees up (`block=False`).

    Each added simulation returns a `Simulation` object that can be monitored
    while running through its `progress`, `status`, `logs`, `is_finished`, and
    `succeeded` properties.

    After `wait()` completes, `succeeded` and `failed` provide shortcuts to
    access completed simulations while preserving the original `Simulation`
    objects.

    A live terminal display is enabled by default. Set `refresh_interval` to
    zero or a negative value to disable terminal output.

    Parameters
    ----------
    max_concurrent : int, optional
        Maximum number of simulations running at the same time.
    refresh_interval : float, optional
        Time in seconds between terminal display updates. A value less than
        or equal to zero disables the display. Defaults to `1.0`.
    block : bool, optional
        When `True`, `add()` blocks while all workers are busy. When `False`,
        `add()` never blocks and pending simulations wait in the worker
        pool's unbounded queue. Defaults to `True`.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        refresh_interval: float = 1.0,
        *,
        block: bool = True,
    ) -> None:
        """Initialize the simulation manager."""
        if max_concurrent < 1:
            raise ValueError("max_concurrent must be at least 1")

        self._display: Display | NullDisplay = (
            Display(refresh_interval=refresh_interval) if refresh_interval > 0 else NullDisplay()
        )

        self._lock: threading.Lock = threading.Lock()
        self._slots: threading.BoundedSemaphore | _UnboundedSlots = (
            threading.BoundedSemaphore(max_concurrent) if block else _UnboundedSlots()
        )
        self._executor: ThreadPoolExecutor = ThreadPoolExecutor(
            max_workers=max_concurrent,
            thread_name_prefix="simulation",
        )

        self._simulations: list[Simulation] = []
        self._futures: list[Future[None]] = []
        self._next_id: int = 0
        self._closed: bool = False

    # -----------------------------------------------------------------
    # Simulation Access
    # -----------------------------------------------------------------
    @property
    def simulations(self) -> list[Simulation]:
        """Return all added simulations in creation order."""
        with self._lock:
            return list(self._simulations)

    # -----------------------------------------------------------------
    # Scheduling
    # -----------------------------------------------------------------
    def add(self, deck_file: str | Path, config: SimulationConfig) -> Simulation:
        """Schedule a simulation.

        Blocks until a worker is available when the manager was created with
        `block=True`; otherwise returns immediately and the
        simulation waits in the queue until a worker picks it up.
        """
        deck_path = Path(deck_file)

        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")

        _ = self._slots.acquire()

        try:
            with self._lock:
                if self._closed:
                    raise RuntimeError("manager is shut down")

                sim_id = self._next_id
                self._next_id += 1

            simulation = Simulation(deck_path, config, sim_id)
            future = self._executor.submit(self._run_and_release, simulation)
        except BaseException:
            self._slots.release()
            raise

        with self._lock:
            self._simulations.append(simulation)
            self._futures.append(future)

        return simulation

    def _notify(
        self,
        callback: Callable[[Simulation], None],
        simulation: Simulation,
    ) -> None:
        """Notify display while ignoring display failures."""
        try:
            callback(simulation)
        except Exception:
            logger.exception("display notification failed for simulation %s", simulation.id)

    def _run_and_release(self, simulation: Simulation) -> None:
        """Execute one simulation and release its worker slot."""
        try:
            self._notify(self._display.simulation_started, simulation)
            try:
                simulation.run()
            finally:
                self._notify(self._display.simulation_finished, simulation)
        finally:
            self._slots.release()

    # -----------------------------------------------------------------
    # Waiting & Results
    # -----------------------------------------------------------------
    def wait(self, timeout: float | None = None) -> bool:
        """Wait for simulations added before this call."""
        with self._lock:
            futures = list(self._futures)

        unfinished = wait_for_futures(futures, timeout=timeout).not_done
        return not unfinished

    @property
    def succeeded(self) -> list[Simulation]:
        """Return simulations that completed successfully."""
        return [sim for sim in self.simulations if sim.succeeded]

    @property
    def failed(self) -> list[Simulation]:
        """Return simulations that completed unsuccessfully."""
        return [sim for sim in self.simulations if sim.is_finished and not sim.succeeded]

    # -----------------------------------------------------------------
    # Shutdown & Context
    # -----------------------------------------------------------------
    def cancel(self) -> None:
        """Request cancellation of all simulations."""
        for simulation in self.simulations:
            simulation.cancel()

    def shutdown(self, *, cancel: bool = False, wait: bool = True) -> None:
        """Shutdown the manager and worker pool."""
        with self._lock:
            if self._closed:
                return
            self._closed = True

        if cancel:
            self.cancel()

        self._executor.shutdown(wait=wait, cancel_futures=cancel)

    def __enter__(self) -> Self:
        """Enter the manager context."""
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Exit the manager context."""
        self.shutdown()
