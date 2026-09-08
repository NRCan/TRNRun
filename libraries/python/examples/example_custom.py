from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(
    max_concurrent=1,
    refresh_interval=0,
) as manager:
    sim = manager.add(r"examples\tpf\example_wo_plot_w_tracking.dck", config)

    # `follow` reads the queue and reports each update until the run finishes.
    for _ in manager.follow():
        progress = sim.progress
        if progress is not None:
            print(f"{progress.percent:6.1%}  (N:{sim.notices} W:{sim.warnings} F:{sim.fatals})", end="\r")

status_event = sim.status
status = status_event.status if status_event is not None else "UNKNOWN"
print(f"\nstatus: {status}  succeeded: {sim.succeeded}")
