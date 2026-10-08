"""Typed requests to one TRNRun daemon, one method per protocol command."""

from __future__ import annotations

import os
from collections.abc import Sequence
from pathlib import Path
from types import TracebackType
from typing import Final, Self, cast

from trnrun.config import BUNDLED_TRNRUN_PATH, BUNDLED_TRNRUND_PATH
from trnrun.events import Changes, parse_simulation_reply
from trnrun.process import DaemonProcess

DEFAULT_MAX_CONCURRENT: Final[int] = max((os.cpu_count() or 1) - 1, 1)


class DaemonClient:
    """Send trnrund protocol requests and return their parsed replies.

    Each method sends one request and waits for its reply. The client keeps no
    state: the caller picks each ``run_id`` and decides when to poll and remove
    runs. Requests from several threads are serialized.

    Parameters
    ----------
    max_concurrent : int, optional
        Simulations the daemon runs at once.
    trnrun_path : str or Path, optional
        TRNRun executable the daemon runs; the bundled one by default.
    trnrund_path : str or Path, optional
        Daemon executable; the bundled one by default.

    Raises
    ------
    FileNotFoundError
        If either executable is missing.
    RuntimeError
        If the daemon rejects its configuration or exits during startup.

    Notes
    -----
    A request the daemon rejects, or a malformed reply, raises ``ValueError``;
    a daemon that exited raises ``RuntimeError``. Release the daemon with
    ``shutdown()`` or ``kill()``; leaving a ``with`` block kills it.
    """

    def __init__(
        self,
        max_concurrent: int = DEFAULT_MAX_CONCURRENT,
        *,
        trnrun_path: str | Path = BUNDLED_TRNRUN_PATH,
        trnrund_path: str | Path = BUNDLED_TRNRUND_PATH,
    ) -> None:
        self._process: DaemonProcess = DaemonProcess(trnrund_path, trnrun_path, max_concurrent)

    def add(self, run_id: str, deck_file: str | Path, trnrun_args: Sequence[str] = ()) -> None:
        """Queue a simulation, which starts once a worker is free.

        Raises ``ValueError`` if ``run_id`` is empty or in use, or the deck is
        missing or not a ``.dck`` or ``.trd`` file.
        """
        _ = self._process.request(
            {"cmd": "add", "runId": run_id, "deckFile": str(deck_file), "trnrunArgs": list(trnrun_args)},
        )

    def changes(self, since: int = 0) -> Changes:
        """Return the daemon's revision and the simulations changed after ``since``.

        Pass the ``revision`` of the previous reply to receive only what
        changed since, with only the new log entries; ``since=0`` returns every
        simulation with all its logs.
        """
        reply = self._process.request({"cmd": "changes", "since": since})
        revision = reply.get("revision")
        if type(revision) is not int:
            raise ValueError("TRNRun daemon reply field 'revision' must be an integer")
        simulations = _objects(reply, "simulations")
        return Changes(revision, {_string(data, "runId"): parse_simulation_reply(data) for data in simulations})

    def remove(self, run_id: str) -> None:
        """Forget a finished simulation, so its run ID can be reused."""
        _ = self._process.request({"cmd": "remove", "runId": run_id})

    def shutdown(self, timeout: float | None = None) -> None:
        """Have the daemon cancel queued runs, finish running ones, and exit.

        Waits for the exit, up to ``timeout`` seconds if given. Requests sent
        afterwards raise ``RuntimeError``. On ``subprocess.TimeoutExpired`` the
        daemon keeps running; ``kill()`` still stops it.
        """
        _ = self._process.request({"cmd": "shutdown"})
        self._process.wait(timeout)

    def kill(self) -> None:
        """Kill the daemon and the simulations it runs; calling it again is harmless."""
        self._process.shutdown()

    def __enter__(self) -> Self:
        """Return the client."""
        return self

    def __exit__(
        self,
        _exc_type: type[BaseException] | None,
        _exc_value: BaseException | None,
        _traceback: TracebackType | None,
    ) -> None:
        """Kill the daemon when leaving the context."""
        self.kill()


def _string(reply: dict[str, object], key: str) -> str:
    """Return a reply field that must be a JSON string."""
    value = reply.get(key)
    if type(value) is not str:
        raise ValueError(f"TRNRun daemon reply field '{key}' must be a string")
    return value


def _objects(reply: dict[str, object], key: str) -> list[dict[str, object]]:
    """Return a reply field that must be a list of JSON objects."""
    value = reply.get(key)
    items = cast("list[object]", value) if type(value) is list else None
    if items is None or not all(type(item) is dict for item in items):
        raise ValueError(f"TRNRun daemon reply field '{key}' must be a list of objects")
    return cast("list[dict[str, object]]", items)
