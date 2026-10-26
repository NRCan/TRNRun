function simulation = example_daemon()
%EXAMPLE_DAEMON Run one deck with the thin Daemon client and poll it until it finishes.
%   SIMULATION = EXAMPLE_DAEMON() adds the repository's Type3830 example
%   deck, prints its progress every second, then prints its outcome,
%   releases it and returns it. Ctrl+C also closes trnrund.

    example_folder = string(fileparts(mfilename("fullpath")));
    addpath(fileparts(example_folder))
    import trnrun.*

    deck_file = fullfile(example_folder, "..", "..", "..", "..", "decks", ...
        "slow_wo_plot_w_tracking.dck");

    daemon = Daemon(workers=1);
    sim_id = daemon.add(deck_file, SimulationSettings(watchTmp=true));
    simulation = daemon.simulation(sim_id);
    while simulation.state ~= "FINISHED"
        % percent is NaN until Type3830 reports progress.
        fprintf("%-8s %3.0f%%\n", simulation.state, 100 * max(simulation.percent, 0));
        pause(1);
        simulation = daemon.simulation(sim_id);
    end
    simulation = daemon.simulation(sim_id, withLogs=true);
    fprintf("%s: succeeded=%d, %d log entries\n", simulation.trnrunStatus, ...
        simulation.succeeded, numel(simulation.logs));
    daemon.release(sim_id);
    delete(daemon);  % close trnrund; the simulation stays readable
end
