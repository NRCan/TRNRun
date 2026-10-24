"""Talk to trnrund: one JSON request line in, one JSON response line out.

Every method mirrors one trnrund command; simulations come back as
``Simulation`` records. ``request`` sends any raw request and returns the
raw response; see trnrund's README for each command.
"""

import json
import subprocess
import threading
from contextlib import suppress
from pathlib import Path
from types import TracebackType
from typing import IO, Any, Self, cast

from trnrun.settings import SimulationSettings
from trnrun.simulation import Simulation, StateName, parse_simulation

BIN = Path(__file__).parent / "bin"
_CLOSE_WAIT = 10.0  # Seconds trnrund gets to exit once stdin closes, before it is killed.


class TrnrunError(Exception):
    """Base of the errors this package raises."""


class RequestError(TrnrunError):
    """trnrund refused a request, such as a missing deck or an unknown simId."""


class DaemonExitedError(TrnrunError):
    """trnrund stopped answering: it was closed, crashed, or failed to start."""


class Daemon:
    """A running trnrund. Thread-safe: requests take turns."""

    def __init__(
        self,
        *,
        workers: int | None = None,
        trnrund_path: str | Path = BIN / "trnrund.exe",
        trnrun_path: str | Path = BIN / "trnrun.exe",
    ) -> None:
        """Start trnrund and check it answers; ``workers`` defaults to the CPU count minus one."""
        args = [str(trnrund_path), f"--trnrun:{Path(trnrun_path).absolute()}"]
        if workers is not None:
            args.append(f"--workers:{workers}")
        self._lock: threading.Lock = threading.Lock()
        self._process: subprocess.Popen[str] = subprocess.Popen(
            args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,  # trnrund writes there only before a fatal exit; read then.
            text=True,
            encoding="utf-8",
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        # Never None: Popen was given PIPE for each.
        self._stdin: IO[str] = cast("IO[str]", self._process.stdin)
        self._stdout: IO[str] = cast("IO[str]", self._process.stdout)
        self._stderr: IO[str] = cast("IO[str]", self._process.stderr)
        try:
            _ = self.request({"cmd": "ready"})
        except BaseException:
            self.close()
            raise

    def request(self, request: dict[str, Any]) -> dict[str, Any]:
        """Send one raw request and return its response; RequestError if trnrund refuses it."""
        with self._lock:
            try:
                _ = self._stdin.write(json.dumps(request) + "\n")
                self._stdin.flush()
                line = self._stdout.readline()
            except (OSError, ValueError):  # Broken pipe, or stdin already closed.
                line = ""
        if not line:
            raise DaemonExitedError(self._exit_message())
        response: dict[str, Any] = json.loads(line)
        if not response["ok"]:
            raise RequestError(response["error"])
        return response

    def add(
        self,
        deck_file: str | Path,
        settings: SimulationSettings | None = None,
        *,
        label: str | None = None,
    ) -> int:
        """Queue a deck and return its simId; ``settings`` None keeps every TRNRun default."""
        args = [] if settings is None else settings.to_cli_args()
        request = {"cmd": "add", "deckFile": str(Path(deck_file).absolute()), "trnrunArgs": args}
        if label is not None:
            request["label"] = label
        return self.request(request)["simId"]

    def get(self, sim_id: int) -> Simulation:
        """Return one simulation, logs included."""
        return parse_simulation(self.request({"cmd": "get", "simId": sim_id})["simulation"])

    def cancel(self, sim_id: int) -> None:
        """Stop a queued or running simulation; RequestError if it already finished."""
        _ = self.request({"cmd": "cancel", "simId": sim_id})

    def release(self, sim_id: int) -> None:
        """Forget a finished simulation and its logs; RequestError if it has not finished."""
        _ = self.request({"cmd": "release", "simId": sim_id})

    def close(self) -> None:
        """Close stdin, so trnrund kills its runs and exits, and wait for it; safe to call again."""
        # A crashed trnrund leaves a flush that fails; the stream is closed regardless.
        with suppress(OSError):
            self._stdin.close()
        try:
            _ = self._process.wait(_CLOSE_WAIT)
        except subprocess.TimeoutExpired:
            self._process.kill()
            _ = self._process.wait()

    def __enter__(self) -> Self:
        """Return this daemon for a with block."""
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Close the daemon when leaving a with block."""
        self.close()

    def _exit_message(self) -> str:
        """Describe why trnrund stopped answering, once its stdout ended."""
        try:
            code = self._process.wait(_CLOSE_WAIT)
        except subprocess.TimeoutExpired:
            return "trnrund closed its output but did not exit"
        stderr = self._stderr.read().strip()
        return f"trnrund exited with code {code}" + (f": {stderr}" if stderr else "")

    # Last on purpose: defined earlier, this method would shadow `list` in the annotations below it.
    def list(self, state: StateName, *, with_logs: bool = False) -> list[Simulation]:
        """Return every unreleased simulation in ``state``, oldest first; without logs unless ``with_logs``."""
        response = self.request({"cmd": "list", "state": state, "withLogs": with_logs})
        return [parse_simulation(sim) for sim in response["simulations"]]
