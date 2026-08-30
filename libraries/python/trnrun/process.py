"""Spawning of TRNRun child processes.

Provides `spawn_process`, which launches one TRNRun execution for a deck
file, merges its stdout and stderr into a single line-buffered text stream,
and applies platform-specific cleanup so the child cannot outlive the parent.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

from trnrun.config import SimulationConfig
from trnrun.jobs import assign_to_job

# -----------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------
CREATE_NO_WINDOW = getattr(subprocess, "CREATE_NO_WINDOW", 0)


# -----------------------------------------------------------------
# Process Spawning
# -----------------------------------------------------------------
def spawn_process(
    deck_file: str | Path,
    config: SimulationConfig,
) -> subprocess.Popen[str]:
    """Spawn a TRNRun process for one deck file.

    Parameters
    ----------
    deck_file : str or Path
        Path to the deck (`.dck`) file to simulate.
    config : SimulationConfig
        Configuration providing the TRNRun executable path and the
        remaining CLI arguments.

    Returns
    -------
    subprocess.Popen
        The running process. Its stdout is line-buffered UTF-8 text with
        stderr merged in, so a single reader drains everything TRNRun
        writes. Use it as a context manager (or close its streams yourself)
        so the pipe is not left open.
    """
    deck_file = Path(deck_file)

    if not deck_file.is_file():
        raise FileNotFoundError(f"Deck file not found: {deck_file}")
    config.validate()

    args = [
        str(config.trnrun_path),
        str(deck_file),
        *config.to_cli_args(),
    ]

    process = subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        encoding="utf-8",
        errors="replace",
        bufsize=1,
        creationflags=CREATE_NO_WINDOW,
    )

    _ = assign_to_job(process)
    return process
