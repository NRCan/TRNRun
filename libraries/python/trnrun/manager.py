"""Launch many simulations on one trnrund, follow them, and show them in the terminal."""

import time
from pathlib import Path
from types import TracebackType
from typing import Self

from trnrun.daemon import BIN, Daemon
from trnrun.display import Display
from trnrun.settings import SimulationSettings
from trnrun.simulation import Simulation, SimulationState, StateName

_ORDER: list[SimulationState] = list(SimulationState)  # QUEUED, RUNNING, FINISHED, in order.


def _rank(state: StateName) -> int:
    """Position of ``state`` in the lifecycle; ValueError unless a ``SimulationState`` or its name."""
    return _ORDER.index(SimulationState(state))


class SimulationManager:
    """Owns one trnrund and keeps a ``Simulation`` per run up to date.

    ``refresh()`` updates each ``Simulation`` in place with trnrund's
    latest, so one returned by ``add()`` stays current. Its ``logs`` are filled
    in once it finishes; trnrund then forgets it.

    Nothing runs in the background: ``add(wait_for=...)`` and ``wait()``
    refresh every ``poll_interval`` seconds while they block, and that is when
    the display moves. Call ``refresh()`` yourself to move it otherwise.
    """

    def __init__(
        self,
        *,
        workers: int | None = None,
        display: bool = True,
        poll_interval: float = 0.5,
        trnrund_path: str | Path = BIN / "trnrund.exe",
        trnrun_path: str | Path = BIN / "trnrun.exe",
    ) -> None:
        """Start trnrund with ``workers`` simulations at once, by default the CPU count minus one."""
        self.daemon: Daemon = Daemon(workers=workers, trnrund_path=trnrund_path, trnrun_path=trnrun_path)
        self.display: Display | None = Display() if display else None
        self.poll_interval: float = poll_interval
        self.simulations: dict[int, Simulation] = {}  # Every simulation added, by simId.

    def add(
        self,
        deck_file: str | Path,
        settings: SimulationSettings | None = None,
        *,
        label: str | None = None,
        wait_for: StateName | None = None,
    ) -> Simulation:
        """Queue a deck and return its simulation.

        ``wait_for`` blocks until the simulation is at least ``QUEUED``,
        ``RUNNING`` or ``FINISHED``; None returns at once. trnrund queues it
        before answering, so ``QUEUED`` returns at once too. A simulation that
        ends without starting, such as a cancelled one, counts as past
        ``RUNNING``. ValueError for another ``wait_for``, before anything is
        queued; RequestError if trnrund refuses the deck or ``settings``.
        """
        if wait_for is not None:
            _ = _rank(wait_for)
        sim_id = self.daemon.add(deck_file, settings, label=label)
        sim = self.simulations[sim_id] = self.daemon.get(sim_id)
        if wait_for is not None:
            self.wait(sim, until=wait_for)
        return sim

    def refresh(self) -> None:
        """Update every simulation from trnrund once, collect the finished ones, and redraw."""
        running = self.daemon.list("RUNNING")
        finished = self.daemon.list("FINISHED", with_logs=True)
        done = {sim.sim_id for sim in finished}
        running = [sim for sim in running if sim.sim_id not in done]  # It finished between the two lists.
        for latest in running + finished:
            sim = self.simulations.setdefault(latest.sim_id, latest)
            if sim is not latest:
                vars(sim).update(vars(latest))  # In place, so the object add() returned stays current.
        for sim in finished:
            self.daemon.release(sim.sim_id)
        if self.display is not None:
            self.display.update(running, finished)

    def wait(
        self,
        *simulations: Simulation,
        until: StateName = SimulationState.FINISHED,
        timeout: float | None = None,
    ) -> None:
        """Block until ``simulations``, by default every one added, are at least ``until``.

        TimeoutError if they are not after ``timeout`` seconds.
        """
        rank = _rank(until)
        targets = simulations or tuple(self.simulations.values())
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            self.refresh()
            if all(_rank(sim.state) >= rank for sim in targets):
                return
            if deadline is not None and time.monotonic() >= deadline:
                raise TimeoutError(f"Simulations not {until} after {timeout} s")
            time.sleep(self.poll_interval)

    def close(self) -> None:
        """Stop trnrund, killing unfinished runs, and erase the live display; safe to call again."""
        self.daemon.close()
        if self.display is not None:
            self.display.close()

    def __enter__(self) -> Self:
        """Return this manager for a with block."""
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Close the manager when leaving a with block."""
        self.close()
