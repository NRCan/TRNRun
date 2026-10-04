import time

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(refresh_interval=0, block=False) as manager:  # 0 disables the built-in display
    sim = manager.add(r"examples\tpf\example_wo_plot_w_tracking.dck", config)

    while not sim.is_finished:
        snap = sim.snapshot()
        if snap.progress is not None:
            print(f"{snap.progress.percent:6.1%}  (N:{snap.notices} W:{snap.warnings} F:{snap.fatals})", end="\r")
        time.sleep(1.0)

    print(f"\nexit code: {sim.exit_code}  succeeded: {sim.succeeded}")
