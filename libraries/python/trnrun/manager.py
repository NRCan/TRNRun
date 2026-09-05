"""Simulation management through one TRNRun daemon process."""

from __future__ import annotations

import os
from dataclasses import replace
from pathlib import Path
from threading import Condition, Event, Thread, current_thread
from types import TracebackType
from typing import Final, Protocol, Self, cast

from trnrun.config import BUNDLED_TRNRUN_PATH, BUNDLED_TRNRUND_PATH, SimulationConfig
from trnrun.events import (
    LogEvent,
    SimulationState,
    SimulationStatus,
    SimulationUpdate,
    parse_log,
    parse_simulation_update,
)
from trnrun.process import SHUTDOWN_TIMEOUT, DaemonProcess
from trnrun.simulation import Simulation

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)
DEFAULT_POLL_INTERVAL: Final[float] = 0.25
SHUTDOWN_REASON: Final[str] = "SimulationManager shut down before the run finished"


class _Tracker(Protocol):
    """An attached observer, such as ``ProgressDisplay``, that the manager hands runs to."""

    def track(self, simulation: Simulation) -> None:
        """Start following an accepted `simulation`; called under the manager lock, so only record it."""

    def close(self) -> None:
        """Stop following runs, after the manager finished every unfinished one."""


class SimulationManager:
    """Submit simulations to one TRNRun daemon process and keep their handles current.

    A background poller asks the daemon for the state of unfinished runs every
    ``poll_interval`` seconds, and immediately after each submission. It fetches
    only new logs, and collects finished runs so the daemon can release them.

    Every ``Simulation`` returned by ``add()`` reaches ``FINISHED`` exactly
    once and never changes afterwards, even if the daemon fails (``ERROR``) or
    the manager shuts down first (``CANCELLED``). Once finished, the manager
    forgets the run; the caller's handle is the only reference left. Read
    handles from any thread with ``Simulation.snapshot()``. Shutdown is
    owner-controlled and must not be concurrent or reentrant.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        *,
        poll_interval: float = DEFAULT_POLL_INTERVAL,
        trnrun_path: str | Path = BUNDLED_TRNRUN_PATH,
        trnrund_path: str | Path = BUNDLED_TRNRUND_PATH,
    ) -> None:
        if not poll_interval > 0:
            raise ValueError("poll_interval must be positive")

        self._condition: Condition = Condition()
        self._wake: Event = Event()
        # Unfinished runs only; `_apply` and `_abandon_unfinished` drop finished ones.
        self._simulations: dict[str, Simulation] = {}
        self._trackers: list[_Tracker] = []
        self._next_id: int = 1
        self._error: BaseException | None = None
        self._closed: bool = False
        self._cleanup_complete: bool = False
        self._poller_stopped: bool = False

        self._process: DaemonProcess = DaemonProcess(trnrund_path, trnrun_path, max_concurrent)
        self._poller: Thread = Thread(
            target=self._poll_loop,
            args=(poll_interval,),
            name="trnrund-poller",
            daemon=True,
        )
        try:
            self._poller.start()
        except BaseException:
            self._process.shutdown()
            raise

    @property
    def active(self) -> list[Simulation]:
        """Return unfinished simulations in submission order, including queued ones."""
        with self._condition:
            return list(self._simulations.values())

    @property
    def error(self) -> BaseException | None:
        """Return the failure that stopped daemon polling, or None while polling works."""
        with self._condition:
            return self._error

    def add(self, deck_file: str | Path, config: SimulationConfig, *, blocking: bool = True) -> Simulation:
        """Submit a simulation and return its live handle.

        By default, waits until a daemon worker accepts the run, so a loop of
        submissions never queues more than the daemon can start. With
        ``blocking=False``, returns as soon as the daemon has queued it; use
        this from a UI thread.

        Raises
        ------
        FileNotFoundError
            If the deck or the configured TRNSYS executable is missing.
        ValueError
            If the daemon rejects the submission, for example an unsupported
            deck extension.
        RuntimeError
            If the manager is closed or daemon polling stopped, including while
            waiting for a worker; the cause is ``error``.
        """
        deck_path: Path = Path(deck_file).absolute()
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        config = replace(config)
        trnrun_args: list[str] = config.to_cli_args()

        with self._condition:
            self._check_usable()
            simulation: Simulation = Simulation(deck_path, config, self._next_id)
            self._next_id += 1
        run_id: str = str(simulation.id)

        _ = self._process.request(
            {"cmd": "add", "runId": run_id, "deckFile": str(deck_path), "trnrunArgs": trnrun_args},
        )
        with self._condition:
            # Nothing would ever finish the run once polling or the manager stopped.
            self._check_usable()
            # Register only once the daemon knows the run, so polls never name unknown runs.
            self._simulations[run_id] = simulation
            self._condition.notify_all()
        self._wake.set()

        if blocking:
            with self._condition:
                _ = self._condition.wait_for(lambda: simulation.is_accepted or self._closed or self._poller_stopped)
                self._check_usable()
        return simulation

    def wait(self, *simulations: Simulation) -> None:
        """Wait until the given simulations, or all unfinished ones, have finished.

        Raises
        ------
        RuntimeError
            If the manager is closed, or daemon polling stopped; the cause is ``error``.
        ValueError
            If an unfinished simulation does not belong to this manager.
        """
        with self._condition:
            self._check_usable()
            for simulation in simulations:
                if not simulation.is_finished and self._simulations.get(str(simulation.id)) is not simulation:
                    raise ValueError("Simulation does not belong to this manager")

            def finished() -> bool:
                if simulations:
                    return all(simulation.is_finished for simulation in simulations)
                return not self._simulations

            _ = self._condition.wait_for(lambda: finished() or self._closed or self._poller_stopped)
            self._check_usable()

    def shutdown(self) -> None:
        """Stop the daemon, finish unfinished runs as CANCELLED, and close attached trackers.

        Incomplete daemon cleanup can be retried.
        """
        with self._condition:
            if self._cleanup_complete:
                return
            self._closed = True
            self._condition.notify_all()
        self._wake.set()

        self._process.shutdown()
        if current_thread() is not self._poller:
            self._poller.join(timeout=SHUTDOWN_TIMEOUT)
            if self._poller.is_alive():
                raise TimeoutError("Timed out waiting for the daemon poller")
        self._abandon_unfinished(SimulationStatus.CANCELLED, SHUTDOWN_REASON)

        with self._condition:
            trackers, self._trackers = self._trackers, []
        self._cleanup_complete = True
        errors: list[Exception] = []
        for tracker in trackers:
            try:
                tracker.close()
            except Exception as error:  # noqa: BLE001 - close every tracker before reporting
                errors.append(error)
        if errors:
            raise errors[0]

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
        """Release the daemon when leaving the context."""
        self.shutdown()

    def _attach(self, tracker: _Tracker) -> None:
        """Hand `tracker` every unfinished accepted run now, and every run once a worker accepts it.

        Queued runs are never handed over, so a long queue costs trackers nothing.
        """
        with self._condition:
            self._check_usable()
            self._trackers.append(tracker)
            for simulation in self._simulations.values():
                if simulation.is_accepted:
                    tracker.track(simulation)

    def _detach(self, tracker: _Tracker) -> None:
        """Stop handing runs to `tracker`; a no-op once shutdown released it."""
        with self._condition:
            if tracker in self._trackers:
                self._trackers.remove(tracker)

    def _check_usable(self) -> None:
        """Raise unless the manager is open and polling; call with the condition held."""
        if self._closed:
            raise RuntimeError("SimulationManager is closed")
        if self._poller_stopped:
            raise RuntimeError("TRNRun daemon polling stopped") from self._error

    def _poll_loop(self, poll_interval: float) -> None:
        """Poll until shutdown; a daemon failure before shutdown escapes the thread."""
        try:
            while True:
                _ = self._wake.wait(poll_interval)
                self._wake.clear()
                with self._condition:
                    if self._closed:
                        return
                    active = list(self._simulations.values())
                self._poll(active)
        except Exception as error:
            with self._condition:
                if self._closed:
                    return  # Shutdown killed the daemon mid-request.
                self._error = error
            raise
        finally:
            self._stop_polling()

    def _stop_polling(self) -> None:
        """Mark polling stopped, failing unfinished runs unless shutdown will cancel them."""
        with self._condition:
            self._poller_stopped = True
            if not self._closed:
                error = self._error
                reason = "TRNRun daemon polling stopped" + (f": {error}" if error is not None else "")
                self._abandon_unfinished(SimulationStatus.ERROR, reason)
            self._condition.notify_all()

    def _abandon_unfinished(self, status: SimulationStatus, reason: str) -> None:
        """Finish and forget every unfinished run with `status`, keeping its last polled state."""
        with self._condition:  # Reentrant: `_stop_polling` already holds it.
            simulations = list(self._simulations.values())
            self._simulations.clear()
            for simulation in simulations:
                _ = simulation.abandon(status, reason)
            self._condition.notify_all()

    def _poll(self, simulations: list[Simulation]) -> None:
        """Refresh `simulations` from one daemon snapshot, fetching logs as needed."""
        if not simulations:
            return

        reply = self._process.request({"cmd": "snapshots", "runIds": [str(item.id) for item in simulations]})
        for simulation, data in zip(simulations, _objects(reply, "simulations"), strict=True):
            run_id = str(simulation.id)
            update: SimulationUpdate = parse_simulation_update(data)
            held: int = simulation.log_count
            if update.state is SimulationState.FINISHED:
                # Collect so the final logs arrive with the finished state, and the daemon forgets the run.
                collected = self._process.request({"cmd": "collect", "runId": run_id})
                update = parse_simulation_update(_object(collected, "simulation"))
                logs = _objects(collected, "logs")[held:]
            elif update.log_count > held:
                # Stop at the snapshot's count, so the logs match its counters.
                request: dict[str, object] = {"cmd": "logs", "runId": run_id, "start": held, "stop": update.log_count}
                logs = _objects(self._process.request(request), "logs")
            else:
                logs = []
            self._apply(simulation, update, [parse_log(entry) for entry in logs])

    def _apply(self, simulation: Simulation, update: SimulationUpdate, logs: list[LogEvent]) -> None:
        """Apply one polled update, hand newly accepted runs to trackers, and forget finished runs."""
        with self._condition:
            if self._closed:
                return
            accepted_before: bool = simulation.is_accepted
            if not simulation.apply_update(update, logs):
                return
            if simulation.is_accepted and not accepted_before:
                # Hand over before the run can be forgotten, so a run accepted and finished
                # within one poll still reaches every tracker.
                for tracker in self._trackers:
                    tracker.track(simulation)
            if simulation.is_finished:
                del self._simulations[str(simulation.id)]
            self._condition.notify_all()


def _object(reply: dict[str, object], key: str) -> dict[str, object]:
    """Return a reply field that must be a JSON object."""
    value = reply.get(key)
    if type(value) is not dict:
        raise ValueError(f"TRNRun daemon reply field '{key}' must be an object")
    return cast("dict[str, object]", value)


def _objects(reply: dict[str, object], key: str) -> list[dict[str, object]]:
    """Return a reply field that must be a list of JSON objects."""
    value = reply.get(key)
    items = cast("list[object]", value) if type(value) is list else None
    if items is None or not all(type(item) is dict for item in items):
        raise ValueError(f"TRNRun daemon reply field '{key}' must be a list of objects")
    return cast("list[dict[str, object]]", items)
