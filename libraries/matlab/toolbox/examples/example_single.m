function simulation = example_single()
%EXAMPLE_SINGLE Run one simulation with manual progress reporting.
%   SIMULATION = EXAMPLE_SINGLE() submits the bundled Type3830 example deck
%   through a manager limited to one concurrent run and waits for it to
%   finish. Function scope keeps the onCleanup guard deterministic.

    example_folder = string(fileparts(mfilename("fullpath")));
    addpath(fileparts(example_folder))
    import trnrun.*

    deck_file = fullfile(example_folder, "dck", "example_wo_plot_w_tracking.dck");

    config = SimulationConfig(watch_tmp=true);
    manager = SimulationManager(maxConcurrent=1, refreshInterval=0.1);

    simulation = manager.add(deck_file, config);
    manager.wait(simulation);
    manager.shutdown();
end
