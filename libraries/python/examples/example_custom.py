"""Example: monitor one simulation without the built-in display."""

from __future__ import annotations

import time

from trnrun import SimulationConfig, SimulationManager


config = SimulationConfig(watch_tmp=True)

with SimulationManager(
    max_concurrent=1,
    max_pending=0,
    refresh_interval=0,
) as manager:
    simulation = manager.add(
        r"examples\tpf\example_wo_plot_w_tracking.dck",
        config,
    )

    while not simulation.is_finished:
        snapshot = simulation.snapshot()
        if snapshot.progress is not None:
            summary = (
                f"{snapshot.progress.percent:6.1%}  "
                f"(N:{snapshot.notices} W:{snapshot.warnings} F:{snapshot.fatals})"
            )
            print(summary, end="\r")
        time.sleep(1.0)

    _ = manager.wait()

status_event = simulation.status
status = status_event.status if status_event is not None else "UNKNOWN"
print(f"\nstatus: {status}  succeeded: {status == 'DONE'}")
