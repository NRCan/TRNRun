function simulation = example_single()
%EXAMPLE_SINGLE Run one simulation with live progress.
%   SIMULATION = EXAMPLE_SINGLE() runs the bundled Type3830 example deck and
%   returns it once finished. Ctrl+C also closes trnrund.

    example_folder = string(fileparts(mfilename("fullpath")));
    addpath(fileparts(example_folder))
    import trnrun.*

    deck_file = fullfile(example_folder, "dck", "slow_wo_plot_w_tracking.dck");

    manager = SimulationManager(workers=1, refreshInterval=0.1);
    simulation = manager.add(deck_file, SimulationSettings(watchTmp=true), ...
        waitFor="FINISHED");
    delete(manager);  % close trnrund; the simulation stays readable
end
