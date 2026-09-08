"""Example: monitor simulations submitted through SimulationManager."""

from __future__ import annotations

import shutil
import time
from pathlib import Path

from trnrun import Simulation, SimulationConfig, SimulationManager

TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")
MASTER_DCK = Path(r"examples\tpf\example_wo_plot_w_tracking.dck")
DCK_FOLDER = Path(r"examples\dck")

SIM_COUNT = 4
MAX_CONCURRENT = 4
POLL_INTERVAL = 2.0
CLEANUP_AFTER = True

CONFIG = SimulationConfig(trnexe_path=TRNEXE_PATH, watch_tmp=True)


def copy_dck(src: Path | str, dst_dir: Path | str, n: int) -> list[Path]:
    """Copy a deck into a directory with zero-padded suffixes."""
    src = Path(src)
    dst_dir = Path(dst_dir)
    _ = dst_dir.mkdir(parents=True, exist_ok=True)

    copies: list[Path] = []
    for index in range(1, n + 1):
        destination = dst_dir / f"{src.stem}_{index:03d}{src.suffix}"
        _ = shutil.copyfile(src, destination)
        copies.append(destination)
    return copies


def cleanup_folder(folder: Path | str) -> None:
    """Remove every file and subdirectory inside a folder."""
    for item in Path(folder).iterdir():
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()


def terminal_status(simulation: Simulation) -> str | None:
    """Return the terminal status, or None while work is active."""
    if not simulation.is_finished:
        return None
    status = simulation.status
    return status.status if status is not None else None


def print_progress(simulations: list[Simulation]) -> None:
    """Print one progress table for every simulation."""
    print("-" * 62)
    for simulation in simulations:
        status = simulation.status.status if simulation.status is not None else "PENDING"
        percent = simulation.progress.percent if simulation.progress is not None else 0.0
        progress_text = f"[{simulation.id}] {status:<9} progress: {percent:6.1%}  "
        log_text = f"warnings: {simulation.warnings}  fatals: {simulation.fatals}"
        print(progress_text + log_text)


def poll_until_done(manager: SimulationManager, simulations: list[Simulation]) -> None:
    """Print progress as queue output arrives until every simulation finishes.

    Simulation state only advances while the manager is reading the queue, so
    the reporting loop is driven by `follow` rather than by sleeping.
    """
    last_print = 0.0
    for _ in manager.follow():
        now = time.monotonic()
        if now - last_print < POLL_INTERVAL:
            continue
        last_print = now
        print_progress(simulations)

    print_progress(simulations)


def report(simulations: list[Simulation]) -> None:
    """Print the terminal result for every simulation."""
    for simulation in simulations:
        status = terminal_status(simulation) or "UNKNOWN"
        print(f"{simulation.deck_path}: {status} (succeeded: {status == 'DONE'})")


def main() -> None:
    """Create, submit, monitor, and optionally remove example decks."""
    decks = copy_dck(MASTER_DCK, DCK_FOLDER, n=SIM_COUNT)

    try:
        with SimulationManager(
            max_concurrent=MAX_CONCURRENT,
            refresh_interval=0,
        ) as manager:
            simulations = [manager.add(deck, CONFIG) for deck in decks]
            poll_until_done(manager, simulations)

        report(simulations)
    finally:
        if CLEANUP_AFTER:
            cleanup_folder(DCK_FOLDER)


if __name__ == "__main__":
    main()
