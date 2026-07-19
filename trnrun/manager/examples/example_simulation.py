"""Example: running multiple TRNSYS simulations with Simulation.

``Simulation.run()`` is blocking: it spawns TRNRun and consumes its stdout
until the process exits. To run several decks concurrently, each ``run()``
gets its own thread, while the main thread polls the thread-safe
properties / snapshots for monitoring.
"""

from __future__ import annotations

import shutil
import threading
import time
from pathlib import Path

from trnrun import Simulation, SimulationConfig

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")
MASTER_DCK = Path(r"examples\tpf\example_wo_plot_w_tracking.dck")
DCK_FOLDER = Path(r"examples\dck")

SIM_COUNT = 4
POLL_INTERVAL = 2.0  # seconds
CLEANUP_AFTER = True

CONFIG = SimulationConfig(trnexe_path=TRNEXE_PATH, watch_tmp=True)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def copy_dck(src: Path | str, dst_dir: Path | str, n: int) -> list[Path]:
    """Copy ``src`` into ``dst_dir`` ``n`` times with a zero-padded suffix."""
    src = Path(src)
    dst_dir = Path(dst_dir)
    dst_dir.mkdir(parents=True, exist_ok=True)

    dst_files: list[Path] = []
    for i in range(1, n + 1):
        dst = dst_dir / f"{src.stem}_{i:03d}{src.suffix}"
        shutil.copyfile(src, dst)
        dst_files.append(dst)
    return dst_files


def cleanup_folder(folder: Path | str) -> None:
    """Remove every file and subdirectory inside ``folder`` (folder is kept)."""
    folder = Path(folder)
    for item in folder.iterdir():
        if item.is_dir():
            shutil.rmtree(item)
        else:
            item.unlink()


# -----------------------------------------------------------------------------
# Run
# -----------------------------------------------------------------------------
def launch_simulations(
    dck_files: list[Path],
) -> tuple[list[Simulation], list[threading.Thread]]:
    """Create one Simulation per deck and start each ``run()`` in a thread."""
    simulations = [Simulation(deck_path=dck, config=CONFIG, sim_id=i) for i, dck in enumerate(dck_files, start=1)]

    threads: list[threading.Thread] = []
    for sim in simulations:
        thread = threading.Thread(target=sim.run, name=f"sim-{sim.id}", daemon=True)
        thread.start()
        threads.append(thread)
        print(f"Launched simulation {sim.id}: {sim.deck_path}")

    return simulations, threads


def describe_state(sim: Simulation) -> str:
    """Human-readable state derived from the process bookkeeping."""
    if sim.is_finished:
        if sim.cancelled:
            return "cancelled"
        if not sim.succeeded:
            return "failed"
        return "finished"
    return "running" if sim.is_running else "starting"


def poll_until_done(simulations: list[Simulation], poll_interval: float) -> None:
    """Print one status line per simulation until all have finished."""
    t0 = time.monotonic()
    while True:
        print("-" * 62)
        all_done = True
        for sim in simulations:
            snap = sim.snapshot()
            # Adjust field/scale here if your ProgressEvent differs.
            percent = snap.progress.percent * 100 if snap.progress else 0.0
            print(
                f"[{snap.id}] {describe_state(sim):<9} "
                f"progress: {percent:5.1f}%  "
                f"logs: {snap.log_count} "
                f"(warnings: {snap.warnings}, fatals: {snap.fatals})"
            )
            if snap.exit_code is None:
                all_done = False

        print(f"elapsed: {time.monotonic() - t0:.1f}s\n")
        if all_done:
            return
        time.sleep(poll_interval)


def report(simulations: list[Simulation]) -> None:
    """Print a final summary for every simulation."""
    for sim in simulations:
        snap = sim.snapshot()
        print("-" * 62)
        print(f"Simulation {snap.id} report:")
        print(f"  Deck:      {snap.deck_path}")
        print(f"  Succeeded: {sim.succeeded}")
        print(f"  Exit code: {snap.exit_code}")
        print(f"  Error:     {snap.error}")
        print(f"  Cancelled: {snap.cancelled}")
        print(
            f"  Logs:      {snap.log_count} (notices: {snap.notices}, warnings: {snap.warnings}, fatals: {snap.fatals})"
        )


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def main() -> None:
    dck_files = copy_dck(MASTER_DCK, DCK_FOLDER, n=SIM_COUNT)
    simulations, threads = launch_simulations(dck_files)

    try:
        poll_until_done(simulations, POLL_INTERVAL)
    except KeyboardInterrupt:
        print("\nInterrupted -- cancelling all simulations")
        for sim in simulations:
            sim.cancel()
    finally:
        for thread in threads:
            thread.join()
        report(simulations)
        if CLEANUP_AFTER:
            cleanup_folder(DCK_FOLDER)


if __name__ == "__main__":
    main()
