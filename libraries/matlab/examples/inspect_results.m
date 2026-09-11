function [simulations, succeeded, failed] = inspect_results(deck_paths)
%INSPECT_RESULTS Run decks and inspect outcomes and retained result data.

    library_path = fileparts(fileparts(mfilename("fullpath")));
    addpath(library_path)

    deck_paths = reshape(string(deck_paths), 1, []);
    config = trnrun.SimulationConfig(watch_tmp=false);
    manager = trnrun.SimulationManager(max_concurrent=4);
    cleanup = onCleanup(@() delete(manager));

    for deck_path = deck_paths
        manager.add(deck_path, config);
    end

    manager.wait();
    manager.shutdown();

    % Results remain readable after graceful shutdown.
    simulations = manager.simulations;
    succeeded = manager.succeeded;
    failed = manager.failed;

    for simulation = simulations
        print_result(simulation);
    end

    clear cleanup
end

function print_result(simulation)
    status = "MISSING";
    if ~isempty(simulation.status)
        status = string(simulation.status.status);
    end

    exit_code = "MISSING";
    if ~isempty(simulation.completionEvent) && ...
            ~isempty(simulation.completionEvent.exitCode) && ...
            ~isnan(simulation.completionEvent.exitCode)
        exit_code = string(simulation.completionEvent.exitCode);
    end

    fprintf("%s\n", char(string(simulation.deckPath)));
    fprintf("  status=%s exit_code=%s succeeded=%d\n", ...
        char(status), char(exit_code), simulation.succeeded);
    fprintf("  logs=%d retained=%d notices=%d warnings=%d fatals=%d\n", ...
        simulation.logCount, numel(simulation.logs), ...
        simulation.notices, simulation.warnings, simulation.fatals);
end
