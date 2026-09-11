function simulation = run_one_deck(deck_path)
%RUN_ONE_DECK Run one deck without requiring Type3830.

    library_path = fileparts(fileparts(mfilename("fullpath")));
    addpath(library_path)

    config = trnrun.SimulationConfig(watch_tmp=false);
    manager = trnrun.SimulationManager(max_concurrent=1);
    cleanup = onCleanup(@() delete(manager));

    simulation = manager.add(deck_path, config);
    manager.wait();
    manager.shutdown();

    status = "UNKNOWN";
    if ~isempty(simulation.status)
        status = string(simulation.status.status);
    end
    fprintf("%s: %s\n", char(string(simulation.deckPath)), char(status));

    clear cleanup
end
