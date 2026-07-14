"""Spawning of TRNRun child processes."""

from __future__ import annotations

import subprocess
import threading
from pathlib import Path

from src.config import TRNRunConfig

# Serializes process creation; see the Notes section of spawn_process.
_spawn_lock = threading.Lock()


def spawn_process(
    deck_file: str | Path,
    config: TRNRunConfig,
) -> subprocess.Popen[str]:
    """Spawn a TRNRun process for one deck file.

    Parameters
    ----------
    deck_file : str or Path
        Path to the deck (``.dck``) file to simulate.
    config : TRNRunConfig
        Configuration providing the TRNRun executable path and the
        remaining CLI arguments.

    Returns
    -------
    subprocess.Popen
        The running process. Its stdout is line-buffered UTF-8 text
        with stderr merged in, so a single reader drains everything
        TRNRun writes.

    Raises
    ------
    FileNotFoundError
        If the deck file or the TRNRun executable does not exist or
        is not a regular file.

    Notes
    -----
    stdin is connected to ``DEVNULL`` so a misbehaving TRNRun can
    never hang waiting for console input. Output decoding uses
    ``errors="replace"`` so a stray non-UTF-8 byte cannot kill the
    stream mid-run; the event parser simply skips lines it cannot
    parse.

    Spawns are serialized with a module-level lock as a precaution
    against handle-inheritance races when creating pipes from several
    threads at once.
    """
    deck_file = Path(deck_file)

    if not deck_file.is_file():
        raise FileNotFoundError(f"Deck file not found: {deck_file}")

    if not config.trnrun_path.is_file():
        raise FileNotFoundError(f"TRNRun executable not found: {config.trnrun_path}")

    args = [
        str(config.trnrun_path),
        str(deck_file),
        *config.to_cli_args(),
    ]

    with _spawn_lock:
        return subprocess.Popen(
            args,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            encoding="utf-8",
            errors="replace",
            bufsize=1,
        )
