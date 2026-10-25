"""Fake TRNRun decks for running the real trnrund.exe with Python as its runner.

trnrund starts the runner as ``<trnrun> <deck> <args...>``, so Python runs the
deck as a script that prints TRNRun's JSON events and exits.
"""

import sys
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from trnrun.daemon import BIN

# The interpreter itself, not a venv redirector, whose child would outlive a cancel.
PYTHON = Path(sys._base_executable)

DONE: list[dict[str, Any]] = [
    {"kind": "STATUS", "status": "RUNNING", "message": ""},
    {"kind": "CONFIG", "start": 0, "stop": 10, "step": 1},
    {"kind": "LOG", "severity": "Warning", "time": 5, "unitId": 7, "typeId": 56, "message": "careful"},
    {"kind": "PROGRESS", "time": 10, "percent": 1, "elapsedMs": 5, "etaMs": 0},
    {"kind": "STATUS", "status": "DONE", "message": ""},
]

_DECK = """\
import json, sys, time
from pathlib import Path

gate = Path(sys.argv[0]).with_suffix(".go")
deadline = time.monotonic() + 30
while {gated} and not gate.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
for event in {events!r}:
    print(json.dumps(event), flush=True)
sys.exit({exit_code})
"""

type DeckWriter = Callable[..., Path]

requires_trnrund = pytest.mark.skipif(not (BIN / "trnrund.exe").is_file(), reason="trnrun/bin/trnrund.exe is missing")


@pytest.fixture
def deck(tmp_path: Path) -> DeckWriter:
    """Return a writer of fake decks; a gated one runs only once ``(deck.with_suffix('.go')).touch()``."""
    count = 0

    def write(*, gated: bool = False, events: list[dict[str, Any]] = DONE, exit_code: int = 0) -> Path:
        """Write a deck that prints ``events`` and exits with ``exit_code``; return its path."""
        nonlocal count
        count += 1
        path = tmp_path / f"deck{count}.dck"
        _ = path.write_text(_DECK.format(gated=gated, events=events, exit_code=exit_code), encoding="utf-8")
        return path

    return write
