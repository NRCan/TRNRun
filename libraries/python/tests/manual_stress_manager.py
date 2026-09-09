"""Manual stress test: 1,000 fast and 100 slow simulations without plots, with tracking.

Run from ``libraries/python`` with::

    uv run python -m tests.manual_stress_manager

Requires TRNSYS, Type3830, and the bundled TRNRun/queue executables. The slow
fixture also requires its referenced TRNSYS weather file. Edit the configuration
below for your installation. Deck copies and outputs are retained in a unique
``tests/runs/stress_*`` directory for inspection; remove it manually when done.
This module is deliberately not named ``test_*`` so pytest will not collect it.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path
from tempfile import mkdtemp
from time import perf_counter

from trnrun import SimulationConfig, SimulationManager

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")
TESTS_DIR = Path(__file__).resolve().parent
FAST_DCK = TESTS_DIR / "dck" / "test_fast_wo_plot_w_tracking.dck"
SLOW_DCK = TESTS_DIR / "dck" / "test_slow_wo_plot_w_tracking.dck"
DCK_FOLDER = TESTS_DIR / "runs"

FAST_SIM_COUNT = 100
SLOW_SIM_COUNT = 100
MAX_CONCURRENT = 50
REFRESH_INTERVAL = 0.1

CONFIG = SimulationConfig(trnexe_path=TRNEXE_PATH, watch_tmp=True)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def copy_dck(src: Path, dst_dir: Path, n: int) -> list[Path]:
    """Copy a fixture with unique, zero-padded names for independent outputs."""
    dst_files: list[Path] = []
    for i in range(1, n + 1):
        dst = dst_dir / f"{src.stem}_{i:04d}{src.suffix}"
        _ = shutil.copyfile(src, dst)
        dst_files.append(dst)
    return dst_files


def run_simulations(dck_files: list[Path]) -> SimulationManager:
    """Submit both workloads to one manager and wait for all runs to finish."""
    with SimulationManager(
        max_concurrent=MAX_CONCURRENT,
        refresh_interval=REFRESH_INTERVAL,
    ) as manager:
        for dck in dck_files:
            _ = manager.add(dck, CONFIG)
        manager.wait()
    return manager


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def main() -> int:
    """Prepare the stress workload and return a failing exit code unless all succeed."""
    CONFIG.validate()
    for source in (FAST_DCK, SLOW_DCK):
        if not source.is_file():
            raise FileNotFoundError(f"Deck file not found: {source}")

    DCK_FOLDER.mkdir(parents=True, exist_ok=True)
    run_folder = Path(mkdtemp(prefix="stress_", dir=DCK_FOLDER))
    print(f"Decks and outputs: {run_folder}", flush=True)
    dck_files = copy_dck(FAST_DCK, run_folder, FAST_SIM_COUNT)
    dck_files.extend(copy_dck(SLOW_DCK, run_folder, SLOW_SIM_COUNT))

    print(f"Running {FAST_SIM_COUNT:,} fast + {SLOW_SIM_COUNT:,} slow simulations (concurrency: {MAX_CONCURRENT}).")
    started = perf_counter()
    manager = run_simulations(dck_files)
    elapsed = perf_counter() - started

    print(
        f"Finished in {elapsed:.1f}s: {len(manager.succeeded):,}/{len(dck_files):,} succeeded, "
        f"{len(manager.failed):,} failed."
    )
    for simulation in manager.failed:
        print(
            f"FAILED {simulation.deck_path.name}: status={simulation.status}, completion={simulation.completion_event}"
        )
    return 0 if len(manager.succeeded) == len(dck_files) else 1


if __name__ == "__main__":
    sys.exit(main())
