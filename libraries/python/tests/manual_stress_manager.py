"""Manual stress test: fast and slow simulations without plots, with tracking.

Run from ``libraries/python`` with::

    uv run python -m tests.manual_stress_manager

Requires TRNSYS, Type3830, and the bundled TRNRun/trnrund executables. The slow
deck also requires its referenced TRNSYS weather file. Edit the configuration
below for your installation. Deck copies and outputs are retained in
``tests/runs`` for inspection. This module is deliberately not named ``test_*``
so pytest will not collect it.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path
from time import perf_counter

from trnrun import SimulationManager, SimulationSettings

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
HERE = Path(__file__).resolve().parent
DECKS = HERE.parents[2] / "decks"

TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")
FAST_DCK = DECKS / "fast_wo_plot_w_tracking.dck"
SLOW_DCK = DECKS / "slow_wo_plot_w_tracking.dck"
DCK_FOLDER = HERE / "runs"

FAST_SIM_COUNT = 50
SLOW_SIM_COUNT = 50
WORKERS = 25
POLL_INTERVAL = 0.1

SETTINGS = SimulationSettings(trnexe_path=TRNEXE_PATH, watch_tmp=True)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def copy_dck(src: Path, dst_dir: Path, n: int) -> list[Path]:
    """Copy a deck with unique, zero-padded names for independent outputs."""
    return [Path(shutil.copyfile(src, dst_dir / f"{src.stem}_{i:04d}{src.suffix}")) for i in range(1, n + 1)]


def run_simulations(dck_files: list[Path]) -> SimulationManager:
    """Submit both workloads to one manager and wait for all runs to finish."""
    with SimulationManager(workers=WORKERS, poll_interval=POLL_INTERVAL) as manager:
        for dck in dck_files:
            _ = manager.add(dck, SETTINGS)

        manager.wait()

    return manager


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def main() -> int:
    """Prepare the stress workload and return a failing exit code unless all succeed."""
    for source in (TRNEXE_PATH, FAST_DCK, SLOW_DCK):
        if not source.is_file():
            raise FileNotFoundError(f"File not found: {source}")

    DCK_FOLDER.mkdir(parents=True, exist_ok=True)

    dck_files = copy_dck(FAST_DCK, DCK_FOLDER, FAST_SIM_COUNT)
    dck_files.extend(copy_dck(SLOW_DCK, DCK_FOLDER, SLOW_SIM_COUNT))

    print(f"Running {FAST_SIM_COUNT:,} fast + {SLOW_SIM_COUNT:,} slow simulations (workers: {WORKERS}).")

    started = perf_counter()
    manager = run_simulations(dck_files)
    elapsed = perf_counter() - started

    failed = [sim for sim in manager.simulations.values() if not sim.succeeded]
    print(
        f"Finished in {elapsed:.1f}s: "
        f"{len(dck_files) - len(failed):,}/{len(dck_files):,} succeeded, "
        f"{len(failed):,} failed."
    )

    for sim in failed:
        print(f"FAILED {sim.deck_file.name}: status={sim.status}, error={sim.error or sim.status_message}")

    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
