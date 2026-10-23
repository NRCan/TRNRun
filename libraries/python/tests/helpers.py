"""Shared test helpers: a reply's SETTING object and fake TRNRun decks.

The daemon and manager tests run the bundled trnrund.exe with Python itself as
the TRNRun executable. trnrund starts TRNRun as ``<trnrun> <deck> <args...>``,
so Python runs the deck as a script, and ``write_deck`` writes decks that print
TRNRun's JSON events and exit with a chosen code.
"""

import sys
from collections.abc import Sequence
from pathlib import Path

import pytest

from trnrun.core.daemon import DEFAULT_TRNRUND

# -----------------------------------------------------------------
# Executables
# -----------------------------------------------------------------
# The interpreter itself, not a venv redirector: trnrund cancels a run by killing TRNRun, and a
# redirector's child would outlive it and keep the output pipe open.
PYTHON = Path(sys._base_executable)
FAKE_TRNRUND = Path(__file__).parent / "fake_trnrund.py"

requires_trnrund = pytest.mark.skipif(
    not DEFAULT_TRNRUND.is_file(),
    reason="trnrun/bin/trnrund.exe is missing; run 'nimble deploy' in components/trnrund",
)

# -----------------------------------------------------------------
# Replies
# -----------------------------------------------------------------
# A SETTING event, as trnrund replies with it: TRNRun's camelCase keys.
SETTING = {
    "trnexePath": r"C:\TRNSYS18\Exe\TrnEXE64.exe",
    "guiVisibility": "hidden",
    "waitForGui": True,
    "waitForLst": True,
    "waitForTmp": False,
    "detectTimeoutMs": 300_000,
    "extraDelayMs": 0,
    "watchLog": True,
    "watchTmp": False,
    "watchTimeoutMs": 0,
    "stallTimeoutMs": 0,
    "pollMs": 100,
    "cleanOnSuccess": False,
    "killOnTimeout": False,
    "killOnStall": False,
    "severity": "Notice",
    "writeEvents": False,
}


# -----------------------------------------------------------------
# Fake TRNRun decks
# -----------------------------------------------------------------
# What a successful run prints: one log entry of each severity, then a DONE status.
DONE_EVENTS: list[dict[str, object]] = [
    {"kind": "STATUS", "status": "RUNNING", "message": ""},
    {"kind": "CONFIG", "start": 0, "stop": 10, "step": 1},
    {"kind": "LOG", "severity": "Notice", "time": 0, "message": "first"},
    {
        "kind": "LOG",
        "severity": "Warning",
        "time": 5,
        "unitId": 7,
        "typeId": 56,
        "messageCode": 123,
        "message": "second",
        "information": "details",
    },
    {"kind": "LOG", "severity": "Fatal", "time": 10, "message": "third"},
    {"kind": "PROGRESS", "time": 10, "percent": 1, "elapsedMs": 5, "etaMs": 0},
    {"kind": "STATUS", "status": "DONE", "message": ""},
]
FAILED_EVENTS: list[dict[str, object]] = [{"kind": "STATUS", "status": "ERROR", "message": "Fake failure"}]
GATE_TIMEOUT = 30.0  # Seconds a gated deck waits for its release before going on anyway.

_DECK = """\
import json, sys, time
from pathlib import Path

release = Path(sys.argv[0]).with_suffix(".release")
deadline = time.monotonic() + {timeout}
while {gated} and not release.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
for event in {events!r}:
    print(json.dumps(event), flush=True)
sys.exit({exit_code})
"""


def write_deck(
    path: Path,
    events: Sequence[dict[str, object]] = DONE_EVENTS,
    *,
    exit_code: int = 0,
    gated: bool = False,
) -> Path:
    """Write a deck that prints ``events`` as TRNRun would, then exits with ``exit_code``.

    A gated deck first waits for ``release(path)``, so a test can hold it
    running.
    """
    _ = path.write_text(
        _DECK.format(timeout=GATE_TIMEOUT, gated=gated, events=list(events), exit_code=exit_code),
        encoding="utf-8",
    )
    return path


def release(deck: Path) -> None:
    """Let a gated deck go on."""
    deck.with_suffix(".release").touch()
