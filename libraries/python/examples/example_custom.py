import time

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(
    max_concurrent=1,
    max_pending=0,
    refresh_interval=0,
) as manager:
    sim = manager.add(r"examples\tpf\example_wo_plot_w_tracking.dck", config)

    while not sim.is_finished:
        snap = sim.snapshot()
        if snap.progress is not None:
            print(f"{snap.progress.percent:6.1%}  (N:{snap.notices} W:{snap.warnings} F:{snap.fatals})", end="\r")
        time.sleep(1.0)

    _ = manager.wait()

status_event = sim.status
status = status_event.status if status_event is not None else "UNKNOWN"
print(f"\nstatus: {status}  succeeded: {sim.succeeded}")
