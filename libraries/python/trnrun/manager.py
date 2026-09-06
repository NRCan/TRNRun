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
from trnrun.events import EventParseError, parse_event_data
from trnrun.simulation import Simulation

logger = logging.getLogger(__name__)

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)
CREATE_NO_WINDOW: Final[int] = getattr(subprocess, "CREATE_NO_WINDOW", 0)


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
        self._next_id: int = 1
        self._closed: bool = False

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
        """Return submitted simulations in creation order."""
        with self._lock:
            return list(self._simulations)

    def add(self, deck_file: str | Path, config: SimulationConfig) -> Simulation:
        """Submit one simulation and return its state object."""
        deck_path = Path(deck_file)
        if not deck_path.is_file():
            raise FileNotFoundError(f"Deck file not found: {deck_path}")
        config.validate()

        with self._lock:
            if self._closed:
                raise RuntimeError("manager is shut down")
            simulation = Simulation(deck_path, config, self._next_id)
            self._next_id += 1
            self._simulations.append(simulation)
            self._by_id[str(simulation.id)] = simulation

        self._notify(self._display.simulation_started, simulation)
        request = {
            "runId": str(simulation.id),
            "deckFile": str(deck_path),
            "runnerPath": str(config.trnrun_path),
            "runnerArgs": config.to_cli_args(),
        }

        try:
            with self._write_lock:
                _ = self._stdin.write(json.dumps(request, separators=(",", ":")) + "\n")
                self._stdin.flush()
        except BaseException:
            with self._lock:
                _ = self._by_id.pop(str(simulation.id), None)
                self._simulations.remove(simulation)
            self._notify(self._display.simulation_finished, simulation)
            raise

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

        with self._write_lock:
            self._stdin.close()

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
        """Route valid queue events until stdout reaches EOF."""
        for line in self._stdout:
            try:
                value = cast("object", json.loads(line))
                if not isinstance(value, dict):
                    continue
                data = cast("dict[str, object]", value)
                run_id = data.get("runId")
                if not isinstance(run_id, str):
                    continue
                event = parse_event_data(data)
            except (json.JSONDecodeError, EventParseError):
                continue

            with self._lock:
                simulation = self._by_id.get(run_id)
            if simulation is None or simulation.is_finished:
                continue

            simulation.apply_event(event)
            if simulation.is_finished:
                with self._lock:
                    _ = self._by_id.pop(run_id, None)
                self._notify(self._display.simulation_finished, simulation)

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
