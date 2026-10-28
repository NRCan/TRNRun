"""Launch many simulations on one trnrund, follow them, and show them in the terminal."""

import time
from pathlib import Path
from types import TracebackType
from typing import Any, Self

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

    Attributes
    ----------
    daemon : Daemon
        The trnrund this manager owns; usable directly for other commands.
    display : Display or None
        Live terminal display, or None when disabled.
    poll_interval : float
        Seconds between refreshes while blocking.
    simulations : dict of int to Simulation
        Every simulation added, by simId.
    """

    def __init__(
        self,
        *,
        workers: int | None = None,
        display: bool = True,
        poll_interval: float = 0.1,
        trnrund_path: str | Path = BIN / "trnrund.exe",
        trnrun_path: str | Path = BIN / "trnrun.exe",
    ) -> None:
        """Start trnrund.

        Parameters
        ----------
        workers : int, optional
            Simulations run at once; trnrund's default, the CPU count minus one, when None.
        display : bool, optional
            Show the simulations live in the terminal or notebook.
        poll_interval : float, optional
            Seconds between refreshes while ``add`` or ``wait`` blocks.
        trnrund_path : str or Path, optional
            trnrund executable; the bundled one by default.
        trnrun_path : str or Path, optional
            TRNRun executable trnrund launches per simulation; the bundled one by default.

        Raises
        ------
        DaemonExitedError
            If trnrund exits before answering.
        """
        self.daemon: Daemon = Daemon(workers=workers, trnrund_path=trnrund_path, trnrun_path=trnrun_path)
        self.display: Display | None = Display() if display else None
        self.poll_interval: float = poll_interval
        self.simulations: dict[int, Simulation] = {}

    def add(
        self,
        deck_file: str | Path,
        settings: SimulationSettings | None = None,
        *,
        label: str | None = None,
        wait_for: StateName | None = None,
        **options: Any,
    ) -> Simulation:
        """Queue a deck and return its simulation.

        Parameters
        ----------
        deck_file : str or Path
            Deck to run; a relative path resolves from Python's working directory.
        settings : SimulationSettings, optional
            TRNRun options; None keeps every TRNRun default.
        label : str, optional
            Free text stored with the simulation, shown instead of the deck path.
        wait_for : SimulationState or str, optional
            Block until the simulation is at least ``QUEUED``, ``RUNNING`` or
            ``FINISHED``; None returns at once. trnrund queues it before
            answering, so ``QUEUED`` returns at once too. A simulation that ends
            without starting, such as a cancelled one, counts as past ``RUNNING``.
        **options
            ``SimulationSettings`` fields, such as ``watch_tmp=True``; they override ``settings``.

        Returns
        -------
        Simulation
            The simulation, kept current by every later ``refresh()``.

        Raises
        ------
        ValueError
            If ``wait_for`` is not a state, before anything is queued.
        TypeError
            If an option is not a ``SimulationSettings`` field.
        RequestError
            If trnrund refuses the deck.
        """
        if wait_for is not None:
            _ = _rank(wait_for)
        sim_id = self.daemon.add(deck_file, settings, label=label, **options)
        sim = self.simulations[sim_id] = self.daemon.simulation(sim_id)
        if wait_for is not None:
            self.wait(sim, until=wait_for)
        return sim

    def cancel(self, *simulations: Simulation) -> None:
        """Stop queued or running simulations; finished ones are left unchanged.

        The next ``refresh()`` shows them ``FINISHED`` with status ``CANCELLED``.

        Parameters
        ----------
        *simulations : Simulation
            Simulations to stop, matched by simId.

        Raises
        ------
        RequestError
            If trnrund does not know a simulation the manager has not seen finish.
        """
        for sim in simulations:
            # A collected one is already released, so trnrund no longer knows its simId.
            if not self.simulations.get(sim.sim_id, sim).is_finished:
                self.daemon.cancel(sim.sim_id)

    def refresh(self) -> None:
        """Update every simulation from trnrund once, collect the finished ones, and redraw."""
        running = self.daemon.simulations("RUNNING")
        finished = self.daemon.simulations("FINISHED", with_logs=True)
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
        """Block until simulations reach a state, refreshing every ``poll_interval`` seconds.

        Parameters
        ----------
        *simulations : Simulation
            Simulations to wait for, matched by simId; every one added by default.
        until : SimulationState or str, optional
            Least state each must reach: ``QUEUED``, ``RUNNING`` or ``FINISHED``.
        timeout : float, optional
            Seconds to wait at most; None waits forever.

        Raises
        ------
        ValueError
            If ``until`` is not a state.
        TimeoutError
            If they have not reached ``until`` after ``timeout`` seconds.
        """
        rank = _rank(until)
        targets = simulations or tuple(self.simulations.values())
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            self.refresh()
            # By simId: a Simulation not returned by add() is never updated in place.
            if all(_rank(self.simulations.get(sim.sim_id, sim).state) >= rank for sim in targets):
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
