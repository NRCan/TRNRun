"""Example: running multiple TRNSYS simulations with SimulationManager."""

from __future__ import annotations

import shutil
from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------
TRNEXE_PATH = Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe")
MASTER_DCK = Path(r"examples\tpf\example_wo_plot_w_tracking.dck")
DCK_FOLDER = Path(r"examples\dck")

SIM_COUNT = 10
MAX_CONCURRENT = 5
MAX_PENDING = 3
REFRESH_INTERVAL = 1
CLEANUP_AFTER = True

CONFIG = SimulationConfig(trnexe_path=TRNEXE_PATH, watch_tmp=True)


# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
def copy_dck(src: Path | str, dst_dir: Path | str, n: int) -> list[Path]:
    """Copy ``src`` into ``dst_dir`` ``n`` times with a zero-padded suffix."""
    src = Path(src)
    dst_dir = Path(dst_dir)
    _ = dst_dir.mkdir(parents=True, exist_ok=True)

    dst_files: list[Path] = []
    for i in range(1, n + 1):
        dst = dst_dir / f"{src.stem}_{i:03d}{src.suffix}"
        _ = shutil.copyfile(src, dst)
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
def run_simulations(dck_files: list[Path]) -> SimulationManager:
    """Launch one simulation per deck and block until all have finished."""
    with SimulationManager(
        max_concurrent=MAX_CONCURRENT,
        max_pending=MAX_PENDING,
        refresh_interval=REFRESH_INTERVAL,
    ) as manager:
        for dck in dck_files:
            _ = manager.add(dck, CONFIG)
        _ = manager.wait()
    return manager


# -----------------------------------------------------------------------------
# Entry point
# -----------------------------------------------------------------------------
def main() -> None:
    """Create, submit, and optionally clean up example decks."""
    dck_files = copy_dck(MASTER_DCK, DCK_FOLDER, n=SIM_COUNT)
    _ = run_simulations(dck_files)

    if CLEANUP_AFTER:
        cleanup_folder(DCK_FOLDER)


if __name__ == "__main__":
    main()
