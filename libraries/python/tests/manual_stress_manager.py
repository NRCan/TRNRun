"""Manual stress test: fast and slow simulations without plots, with tracking.

Run from ``libraries/python`` with::

    uv run python -m tests.manual_stress_manager

Requires TRNSYS, Type3830, and the bundled TRNRun/daemon executables. The slow
fixture also requires its referenced TRNSYS weather file. Edit the configuration
below for your installation. Deck copies and outputs are retained directly in
``tests/runs`` for inspection. This module is deliberately not named ``test_*``
so pytest will not collect it.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path
from time import perf_counter

from trnrun import Simulation, SimulationConfig, SimulationManager

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
__root__ = Path(__file__).resolve().parent

TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")
FAST_DCK = __root__ / "dck" / "test_fast_wo_plot_w_tracking.dck"
SLOW_DCK = __root__ / "dck" / "test_slow_wo_plot_w_tracking.dck"
DCK_FOLDER = __root__ / "runs"

FAST_SIM_COUNT = 0
SLOW_SIM_COUNT = 50
MAX_CONCURRENT = 25
REFRESH_INTERVAL = 0.1

CONFIG = SimulationConfig(
    trnexe_path=TRNEXE_PATH,
    watch_tmp=True,
)


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


def run_simulations(dck_files: list[Path]) -> list[Simulation]:
    """Submit both workloads to one manager and wait for all runs to finish."""
    with SimulationManager(max_concurrent=MAX_CONCURRENT, refresh_interval=REFRESH_INTERVAL) as manager:
        simulations = [manager.add(dck, CONFIG) for dck in dck_files]
        manager.wait()

    return simulations


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def main() -> int:
    """Prepare the stress workload and return a failing exit code unless all succeed."""
    _ = CONFIG.to_cli_args()  # Fail on a missing TRNSYS before copying decks.

    for source in (FAST_DCK, SLOW_DCK):
        if not source.is_file():
            raise FileNotFoundError(f"Deck file not found: {source}")

    DCK_FOLDER.mkdir(parents=True, exist_ok=True)

    # print(f"Decks and outputs: {DCK_FOLDER}", flush=True)

    dck_files = copy_dck(FAST_DCK, DCK_FOLDER, FAST_SIM_COUNT)
    dck_files.extend(copy_dck(SLOW_DCK, DCK_FOLDER, SLOW_SIM_COUNT))

    print(f"Running {FAST_SIM_COUNT:,} fast + {SLOW_SIM_COUNT:,} slow simulations (concurrency: {MAX_CONCURRENT}).")

    started = perf_counter()
    simulations = run_simulations(dck_files)
    elapsed = perf_counter() - started
    failed = [simulation for simulation in simulations if not simulation.succeeded]

    print(
        f"Finished in {elapsed:.1f}s: ",
        f"{len(simulations) - len(failed):,}/{len(dck_files):,} succeeded, ",
        f"{len(failed):,} failed.",
    )

    for simulation in failed:
        print(
            f"FAILED {simulation.deck_path.name}: status={simulation.status}, "
            f"exit_code={simulation.exit_code}, error={simulation.error!r}",
        )

    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
