"""Manage simulations through one TRNRun Queue process."""

from __future__ import annotations

import json
import logging
import os
import subprocess
import threading
import time
from collections.abc import Callable
from pathlib import Path
from types import TracebackType
from typing import IO, Final, Self, cast

from trnrun.config import BUNDLED_TRNRUNQ_PATH, SimulationConfig
from trnrun.display import Display, NullDisplay
from trnrun.events import EventParseError, StatusEvent, parse_event_data
from trnrun.job import assign_to_job
from trnrun.simulation import Simulation

logger = logging.getLogger(__name__)

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)
CREATE_NO_WINDOW: Final[int] = getattr(subprocess, "CREATE_NO_WINDOW", 0)


class _Acceptance:
    """Completion signal for one queue submission."""

    def __init__(self) -> None:
        self.event: threading.Event = threading.Event()
        self.error: str | None = None


class SimulationManager:
    """Submit and monitor simulations through one `trnrunq.exe` process."""

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        max_pending: int = 0,
        refresh_interval: float = 1.0,
        *,
        trnrunq_path: str | Path = BUNDLED_TRNRUNQ_PATH,
    ) -> None:
        """Start the queue process and its output reader."""
        if max_concurrent < 1:
            raise ValueError("max_concurrent must be at least 1")
        if max_pending < 0:
            raise ValueError("max_pending must be at least 0")

        trnrunq_path = Path(trnrunq_path)
        if not trnrunq_path.is_file():
            raise FileNotFoundError(f"TRNRun queue executable not found: {trnrunq_path}")

        self._display: Display | NullDisplay = (
            Display(refresh_interval=refresh_interval) if refresh_interval > 0 else NullDisplay()
        )
        self._lock: threading.Lock = threading.Lock()
        self._write_lock: threading.Lock = threading.Lock()
        self._simulations: list[Simulation] = []
        self._by_id: dict[str, Simulation] = {}
        self._acceptances: dict[str, _Acceptance] = {}
        self._published_ids: set[str] = set()
        self._finished_notified_ids: set[str] = set()
        self._next_id: int = 1
        self._closed: bool = False
        self._queue_error: str | None = None

        self._process: subprocess.Popen[str] = subprocess.Popen(
            [
                str(trnrunq_path),
                f"--maxConcurrent:{max_concurrent}",
                f"--maxPending:{max_pending}",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
            creationflags=CREATE_NO_WINDOW,
        )
        _ = assign_to_job(self._process)
        self._stdin: IO[str] = self._require_stream(self._process.stdin, "stdin")
        self._stdout: IO[str] = self._require_stream(self._process.stdout, "stdout")
        self._reader: threading.Thread = threading.Thread(
            target=self._read_output,
            name="trnrunq-output",
            daemon=True,
        )
        self._reader.start()

    @property
    def simulations(self) -> list[Simulation]:
        """Return queue-accepted simulations in creation order."""
        with self._lock:
            return list(self._simulations)

    def add(self, deck_file: str | Path, config: SimulationConfig) -> Simulation:
        """Submit one simulation, blocking until the queue accepts it."""
        deck_path = Path(deck_file)
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        config.validate()

        acceptance = _Acceptance()
        with self._lock:
            if self._closed:
                raise RuntimeError("manager is shut down")
            if self._queue_error is not None:
                raise RuntimeError(self._queue_error)

            simulation = Simulation(deck_path, config, self._next_id)
            self._next_id += 1
            run_id = str(simulation.id)
            self._by_id[run_id] = simulation
            self._acceptances[run_id] = acceptance
        request = {
            "runId": run_id,
            "deckFile": str(deck_path),
            "runnerPath": str(config.trnrun_path),
            "runnerArgs": config.to_cli_args(),
        }

        try:
            with self._write_lock:
                _ = self._stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
                self._stdin.flush()
        except BaseException:
            self._discard_submission(run_id, simulation)
            raise

        _ = acceptance.event.wait()
        if acceptance.error is not None:
            self._discard_submission(run_id, simulation)
            raise RuntimeError(acceptance.error)

        self._publish_submission(run_id, simulation)
        return simulation

    def wait(self, timeout: float | None = None) -> bool:
        """Wait for simulations added before this call to finish."""
        simulations = self.simulations
        deadline = None if timeout is None else time.monotonic() + timeout

        for simulation in simulations:
            remaining = None if deadline is None else max(deadline - time.monotonic(), 0.0)
            if not simulation.wait(remaining):
                return False
        return True

    @property
    def succeeded(self) -> list[Simulation]:
        """Return simulations that completed successfully."""
        return [simulation for simulation in self.simulations if simulation.succeeded]

    @property
    def failed(self) -> list[Simulation]:
        """Return simulations that completed without succeeding."""
        return [simulation for simulation in self.simulations if simulation.is_finished and not simulation.succeeded]

    def shutdown(self) -> None:
        """Close queue input and drain all accepted simulations."""
        with self._lock:
            if self._closed:
                return
            self._closed = True

        try:
            with self._write_lock:
                self._stdin.close()
        except (BrokenPipeError, OSError, ValueError):
            pass
        finally:
            self._reader.join()
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

    def _read_output(self) -> None:
        """Route queue acknowledgments and runner events through stdout EOF."""
        try:
            for line in self._stdout:
                try:
                    value = cast("object", json.loads(line))
                    if not isinstance(value, dict):
                        continue
                    data = cast("dict[str, object]", value)
                    run_id = data.get("runId")
                    kind = data.get("kind")
                    if not isinstance(run_id, str) or not isinstance(kind, str):
                        continue

                    if kind == "QUEUE":
                        self._handle_queue_event(run_id, data)
                        continue

                    event = parse_event_data(data)
                except (json.JSONDecodeError, EventParseError):
                    continue

                with self._lock:
                    simulation = self._by_id.get(run_id)
                if simulation is None or simulation.is_finished:
                    continue

                simulation.apply_event(event)
        finally:
            self._handle_queue_eof()

    def _handle_queue_event(self, run_id: str, data: dict[str, object]) -> None:
        """Handle one queue lifecycle event."""
        event = data.get("event")
        if not isinstance(event, str):
            return

        match event:
            case "ACCEPTED":
                with self._lock:
                    acceptance = self._acceptances.pop(run_id, None)
                if acceptance is not None:
                    acceptance.event.set()

            case "COMPLETED":
                self._reconcile_completion(run_id, data)
            case _:
                return

    def _reconcile_completion(self, run_id: str, data: dict[str, object]) -> None:
        """Fail a completed child that produced no valid terminal status."""
        with self._lock:
            simulation = self._by_id.get(run_id)
        if simulation is None or simulation.is_finished:
            return

        exit_code = data.get("exitCode")
        exit_detail = (
            f" with code {exit_code}"
            if isinstance(exit_code, int) and not isinstance(exit_code, bool)
            else ""
        )
        if not simulation.has_terminal_status:
            message = f"TRNRun exited{exit_detail} without a terminal STATUS event"
            timestamp = data.get("timestamp")
            if not isinstance(timestamp, str):
                timestamp = time.strftime("%Y-%m-%dT%H:%M:%S")
            simulation.apply_event(StatusEvent(status="ERROR", timestamp=timestamp, message=message))

        simulation.mark_completed()
        with self._lock:
            _ = self._by_id.pop(run_id, None)
        self._notify_finished_if_published(run_id, simulation)

    def _handle_queue_eof(self) -> None:
        """Fail unaccepted submissions and runs missing terminal statuses."""
        exit_code = self._process.wait()
        queue_error = f"TRNRun queue exited with code {exit_code}"

        with self._lock:
            self._queue_error = queue_error
            pending = list(self._acceptances.items())
            self._acceptances.clear()
            pending_ids = {run_id for run_id, _acceptance in pending}

            incomplete: list[Simulation] = []
            for run_id, simulation in list(self._by_id.items()):
                if run_id not in pending_ids:
                    incomplete.append(simulation)
                    del self._by_id[run_id]

        for run_id, acceptance in pending:
            acceptance.error = f"{queue_error} before accepting simulation {run_id}"
            acceptance.event.set()

        timestamp = time.strftime("%Y-%m-%dT%H:%M:%S")
        for simulation in incomplete:
            simulation.apply_event(
                StatusEvent(status="ERROR", timestamp=timestamp, message=queue_error),
            )
            simulation.mark_completed()
            self._notify_finished_if_published(str(simulation.id), simulation)

    def _publish_submission(self, run_id: str, simulation: Simulation) -> None:
        """Expose a simulation only after the queue accepts it."""
        self._notify(self._display.simulation_started, simulation)

        with self._lock:
            self._simulations.append(simulation)
            self._published_ids.add(run_id)
            notify_finished = simulation.is_finished and run_id not in self._finished_notified_ids
            if notify_finished:
                self._finished_notified_ids.add(run_id)

        if notify_finished:
            self._notify(self._display.simulation_finished, simulation)

    def _notify_finished_if_published(self, run_id: str, simulation: Simulation) -> None:
        """Notify completion once, after a simulation has been published."""
        with self._lock:
            if run_id not in self._published_ids or run_id in self._finished_notified_ids:
                return
            self._finished_notified_ids.add(run_id)

        self._notify(self._display.simulation_finished, simulation)

    def _discard_submission(self, run_id: str, simulation: Simulation) -> None:
        """Remove a submission that the queue did not accept."""
        with self._lock:
            _ = self._acceptances.pop(run_id, None)
            _ = self._by_id.pop(run_id, None)
            self._published_ids.discard(run_id)
            self._finished_notified_ids.discard(run_id)
            if simulation in self._simulations:
                self._simulations.remove(simulation)

    @staticmethod
    def _notify(callback: Callable[[Simulation], None], simulation: Simulation) -> None:
        """Notify the display without interrupting queue processing."""
        try:
            callback(simulation)
        except Exception:
            logger.exception("display notification failed for simulation %s", simulation.id)

    @staticmethod
    def _require_stream(stream: IO[str] | None, name: str) -> IO[str]:
        """Return a configured queue stream."""
        if stream is None:
            raise RuntimeError(f"queue {name} is unavailable")
        return stream
