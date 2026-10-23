"""Simulation handles kept in sync with one trnrund daemon."""

from contextlib import ExitStack, suppress
from dataclasses import replace
from pathlib import Path
from time import monotonic, sleep
from types import TracebackType
from typing import Final, Self

from trnrun.core.daemon import DEFAULT_TRNRUN, DEFAULT_TRNRUND, Daemon, StateName
from trnrun.core.errors import ClosedError, TrnrunError
from trnrun.core.records import SimulationState
from trnrun.core.settings import SimulationSettings
from trnrun.display import Display, ProgressDisplay
from trnrun.simulation import Simulation

DEFAULT_REFRESH_INTERVAL: Final[float] = 1.0
_SHUTDOWN_WAIT: Final[float] = 10.0  # Longest shutdown() waits for killed runs to finish.
_SHUTDOWN_POLL: Final[float] = 0.05  # How often shutdown() checks whether they did.
_LIFECYCLE: Final[list[SimulationState]] = list(SimulationState)  # QUEUED, RUNNING, FINISHED, in order.


class SimulationManager:
    """Own one trnrund daemon and keep its simulations' handles in sync.

    Nothing runs in the background: ``refresh()`` syncs once, asking the
    daemon for each tracked run, applying it to the handles, showing it on the
    display, then releasing finished runs from the daemon. ``wait()``, and
    ``add()`` with ``wait_for``, call it every ``refresh_interval`` seconds
    until the runs get there. Handles change only inside these calls, so the
    display only moves while one runs; call ``refresh()`` from your own loop
    or timer to keep it moving otherwise.

    By default the manager shows its runs with a ``ProgressDisplay``. Pass
    ``display=False`` to show them yourself, for example from a GUI timer that
    calls ``refresh()`` and reads the handles, or any ``Display``. The display
    is closed on ``shutdown()``.

    If the daemon exits, the next call raises ``DaemonExitedError`` instead of
    hanging; after ``shutdown()`` calls that need the daemon raise
    ``ClosedError``. Handles keep their last state.

    Call every method from one thread. Use ``Daemon`` directly when an
    application needs to control polling itself.
    """

    def __init__(
        self,
        *,
        max_concurrent: int | None = None,
        trnrund_path: str | Path = DEFAULT_TRNRUND,
        trnrun_path: str | Path = DEFAULT_TRNRUN,
        refresh_interval: float = DEFAULT_REFRESH_INTERVAL,
        display: bool | Display = True,
    ) -> None:
        """Start the daemon.

        max_concurrent defaults to one less than the CPU count, at least 1.
        trnrund_path and trnrun_path are passed to ``Daemon``. Startup
        failures raise as they do there.
        """
        if refresh_interval < 0:
            raise ValueError("refresh_interval must not be negative")
        # Unwound by shutdown: the daemon, then the display.
        self._resources: ExitStack = ExitStack()
        self.display: Display | None = ProgressDisplay() if display is True else (display or None)
        if self.display is not None:
            _ = self._resources.callback(self.display.close)
        try:
            self._daemon: Daemon = self._resources.enter_context(
                Daemon(max_concurrent=max_concurrent, trnrund_path=trnrund_path, trnrun_path=trnrun_path),
            )
        except BaseException:
            self._resources.close()
            raise
        self._refresh_interval: float = refresh_interval
        # Unfinished runs, and finished ones until their final display update, by run ID.
        self._simulations: dict[int, Simulation] = {}
        self._closed: bool = False

    @property
    def active(self) -> list[Simulation]:
        """Return the unfinished simulations in submission order, including queued ones."""
        return [simulation for simulation in self._simulations.values() if not simulation.is_finished]

    def add(
        self,
        deck_file: str | Path,
        settings: SimulationSettings | None = None,
        *,
        label: str | None = None,
        wait_for: StateName = SimulationState.QUEUED,
    ) -> Simulation:
        """Queue a deck and return its handle.

        The run starts once a slot is free. ``settings`` defaults to
        ``SimulationSettings()``, which keeps TRNRun's defaults; it is copied,
        so it can be changed and reused for later submissions. ``label`` is
        kept with the run. A relative ``deck_file`` resolves from the current
        working directory.

        Returns once the handle reaches ``wait_for``, a ``SimulationState`` or
        its name, or a later state, refreshing meanwhile. The default
        ``QUEUED`` returns at once; ``RUNNING`` also returns for a run that
        finished without starting; ``FINISHED`` returns as ``wait()`` does,
        after the final display update.

        Raises
        ------
        ValueError
            If ``wait_for`` is not a ``SimulationState`` name; nothing is queued.
        FileNotFoundError
            If the configured TRNSYS executable is missing.
        RequestRejectedError
            If the daemon rejects the run, such as for a missing deck or one
            that is not a ``.dck`` or ``.trd`` file.
        ClosedError
            If the manager was shut down.
        DaemonExitedError
            If the daemon exited, including while waiting for ``wait_for``.
        """
        settings = SimulationSettings() if settings is None else replace(settings)
        deck_file = Path(deck_file).absolute()
        wait_for = SimulationState(wait_for)
        self._check()
        info = self._daemon.add(deck_file, settings, label=label)
        simulation = Simulation(info.run_id, deck_file, settings)
        simulation._apply(info)  # noqa: SLF001 # pyright: ignore[reportPrivateUsage] - the manager is its only writer
        self._simulations[info.run_id] = simulation
        while not self._has_reached(simulation, wait_for):
            self.refresh()
            if not self._has_reached(simulation, wait_for):
                sleep(self._refresh_interval)
        return simulation

    def cancel(self, simulation: Simulation) -> None:
        """Stop a queued or running simulation; it finishes as CANCELLED shortly after.

        A finished simulation is left unchanged, keeping its real outcome.

        Raises
        ------
        ValueError
            If the simulation is unfinished but was not added to this manager.
        ClosedError
            If the manager was shut down.
        DaemonExitedError
            If the daemon exited.
        """
        self._check()
        self._check_owned(simulation)
        if self._is_pending(simulation):
            self._daemon.cancel(simulation.run_id)

    def refresh(self) -> None:
        """Sync the handles once: apply what changed, show it, then release finished runs.

        A display failure is ignored and never stops syncing.

        Raises
        ------
        ClosedError
            If the manager was shut down.
        DaemonExitedError
            If the daemon exited.
        """
        self._check()
        changed: list[Simulation] = []
        for simulation in self._simulations.values():
            info = self._daemon.get(simulation.run_id)
            if info != simulation.info:
                changed.append(simulation)
            simulation._apply(info)  # noqa: SLF001 # pyright: ignore[reportPrivateUsage] - the manager is its only writer

        if changed and self.display is not None:
            with suppress(Exception):
                self.display.update(changed)

        # A finished run has all its logs in. Kept tracked until displayed,
        # so wait() returns only after their final lines.
        finished = [run_id for run_id, simulation in self._simulations.items() if simulation.is_finished]
        for run_id in finished:
            self._daemon.release(run_id)
            _ = self._simulations.pop(run_id)

    def wait(self, simulation: Simulation | None = None, *, timeout: float | None = None) -> None:
        """Block until ``simulation`` has finished, or every run if None, including those added meanwhile.

        Refreshes every ``refresh_interval`` seconds meanwhile, and returns
        only after the final display updates; failed runs finish too, so
        check ``Simulation.succeeded``. Returns at once for runs that already
        finished, even after shutdown.

        Raises
        ------
        TimeoutError
            If runs are unfinished after ``timeout`` seconds.
        ValueError
            If the simulation is unfinished but was not added to this manager.
        ClosedError
            If runs are unfinished and the manager was shut down.
        DaemonExitedError
            If the daemon exited.
        """
        deadline = None if timeout is None else monotonic() + timeout
        if simulation is not None:
            self._check_owned(simulation)
        while self._is_pending(simulation):
            self.refresh()
            if not self._is_pending(simulation):
                return
            remaining = None if deadline is None else deadline - monotonic()
            if remaining is not None and remaining <= 0:
                raise TimeoutError("Simulations did not finish within the timeout")
            sleep(self._refresh_interval if remaining is None else min(self._refresh_interval, remaining))

    def shutdown(self) -> None:
        """Cancel unfinished runs, collect their final state, then stop the daemon and close the display.

        Queued runs are cancelled and running ones killed; their handles
        finish as CANCELLED. Later calls do nothing.
        """
        if self._closed:
            return
        try:
            # A daemon that exited already has nothing left to collect.
            with suppress(TrnrunError):
                self._daemon.shutdown(cancel_running=True)
                deadline = monotonic() + _SHUTDOWN_WAIT
                while self._simulations and monotonic() < deadline:
                    self.refresh()
                    if self._simulations:
                        sleep(_SHUTDOWN_POLL)
        finally:
            self._closed = True
            self._resources.close()

    def __enter__(self) -> Self:
        """Enter the manager before shutdown."""
        self._check()
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Shut the manager down when leaving the context."""
        self.shutdown()

    def _is_pending(self, simulation: Simulation | None) -> bool:
        """Return whether ``wait(simulation)`` must keep waiting."""
        if simulation is None:
            return bool(self._simulations)
        return self._simulations.get(simulation.run_id) is simulation

    def _has_reached(self, simulation: Simulation, state: SimulationState) -> bool:
        """Return whether ``simulation`` is at ``state`` or later."""
        if state is SimulationState.FINISHED:
            return not self._is_pending(simulation)  # As wait(): only after the final display update.
        return _LIFECYCLE.index(simulation.state) >= _LIFECYCLE.index(state)

    def _check_owned(self, simulation: Simulation) -> None:
        """Raise ValueError for an unfinished simulation this manager does not track."""
        if not self._is_pending(simulation) and not simulation.is_finished:
            raise ValueError(f"Simulation {simulation.run_id} was not added to this manager")

    def _check(self) -> None:
        """Raise ClosedError once the manager was shut down."""
        if self._closed:
            raise ClosedError("SimulationManager is closed")
