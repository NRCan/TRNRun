"""Start trnrund, submit runs to it, and ask for their state."""

# pyright: reportAny=false, reportExplicitAny=false

from collections.abc import Sequence
from pathlib import Path
from types import TracebackType
from typing import Any, Literal, Self, cast

from trnrun.core._process import DaemonProcess
from trnrun.core.errors import ProtocolVersionError
from trnrun.core.records import SimulationInfo, SimulationState, parse_run
from trnrun.core.settings import SimulationSettings

DEFAULT_TRNRUN = Path(__file__).parents[1] / "bin" / "trnrun.exe"
DEFAULT_TRNRUND = Path(__file__).parents[1] / "bin" / "trnrund.exe"
PROTOCOL_VERSION = 2

type StateName = SimulationState | Literal["QUEUED", "RUNNING", "FINISHED"]


class Daemon:
    """A running trnrund: submit runs and ask for their state, on the caller's thread.

    trnrund keeps every run and its logs in memory until ``release()``, and
    ``get()`` reads one with all its logs; poll it to follow a run. Each
    method sends one request and returns its reply; nothing runs in the
    background. Every method is thread-safe: requests take turns, so an
    ``add()`` that waits for its run holds the others back.
    """

    def __init__(
        self,
        *,
        max_concurrent: int | None = None,
        trnrund_path: str | Path = DEFAULT_TRNRUND,
        trnrun_path: str | Path = DEFAULT_TRNRUN,
    ) -> None:
        """Start trnrund and check that it speaks this package's protocol.

        ``max_concurrent`` defaults to the CPU count minus one. Raises
        DaemonExitedError if trnrund fails to start, and ProtocolVersionError
        if it speaks another protocol version.
        """
        args = [f"--trnrun:{Path(trnrun_path).absolute()}"]
        if max_concurrent is not None:
            args.append(f"--maxConcurrent:{max_concurrent}")
        process = DaemonProcess(trnrund_path, args)
        try:
            version = process.request({"cmd": "ready"}).get("protocolVersion")
        except BaseException:
            process.close()
            raise
        if version != PROTOCOL_VERSION:
            process.close()
            raise ProtocolVersionError(f"trnrund speaks protocol {version}; this package needs {PROTOCOL_VERSION}")
        self._process: DaemonProcess = process

    def add(
        self,
        deck_file: str | Path,
        trnrun_args: Sequence[str] | SimulationSettings = (),
        *,
        label: str | None = None,
        wait_for: StateName = SimulationState.QUEUED,
    ) -> SimulationInfo:
        """Submit a deck and return its run once it reaches ``wait_for`` or a later state.

        The default ``QUEUED`` returns at once; ``RUNNING`` and ``FINISHED``
        block this thread until the run gets there, and the returned run is
        then its outcome. Raises ValueError for an unknown ``wait_for``, and
        RequestRejectedError if trnrund refuses the run.
        """
        args = trnrun_args.to_cli_args() if isinstance(trnrun_args, SimulationSettings) else list(trnrun_args)
        request: dict[str, object] = {
            "cmd": "add",
            "deckFile": str(Path(deck_file).absolute()),
            "trnrunArgs": args,
            "waitFor": SimulationState(wait_for).value,
        }
        if label is not None:
            request["label"] = label
        return parse_run(cast("dict[str, Any]", self._process.request(request)["run"]))

    def get(self, run_id: int) -> SimulationInfo:
        """Return one run with all its logs; raise RequestRejectedError for an unknown or released run ID."""
        return parse_run(cast("dict[str, Any]", self._process.request({"cmd": "get", "runId": run_id})["run"]))

    def release(self, run_id: int) -> None:
        """Delete a finished run and its logs from trnrund; an unknown or released ID is skipped.

        Raises RequestRejectedError if the run has not finished.
        """
        _ = self._process.request({"cmd": "release", "runId": run_id})

    def cancel(self, run_id: int) -> None:
        """Stop a queued or running run, leaving a finished one unchanged; raise RequestRejectedError for an unknown ID."""
        _ = self._process.request({"cmd": "cancel", "runId": run_id})

    def shutdown(self, *, cancel_running: bool = False) -> None:
        """Cancel queued runs and refuse new ones; ``cancel_running`` also kills running ones.

        trnrund keeps answering, so the last results can still be read, until ``close()``.
        """
        _ = self._process.request({"cmd": "shutdown", "cancelRunning": cancel_running})

    def close(self) -> None:
        """Stop trnrund, killing unfinished runs and dropping every run it held; safe to call again."""
        self._process.close()

    def __enter__(self) -> Self:
        """Return this daemon for use in a with block."""
        return self

    def __exit__(
        self,
        exc_type: type[BaseException] | None,
        exc_value: BaseException | None,
        traceback: TracebackType | None,
    ) -> None:
        """Close the daemon when leaving a with block."""
        self.close()
