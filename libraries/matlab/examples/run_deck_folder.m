function simulations = run_deck_folder(deck_folder)
%RUN_DECK_FOLDER Run all .dck files in a folder with bounded concurrency.

    library_path = fileparts(fileparts(mfilename("fullpath")));
    addpath(library_path)

    files = dir(fullfile(char(string(deck_folder)), "*.dck"));
    if isempty(files)
        error("trnrun:examples:NoDecks", ...
            "No .dck files found in %s", char(string(deck_folder)));
    end

    [~, order] = sort(lower(string({files.name})));
    files = files(order);

    config = trnrun.SimulationConfig(watch_tmp=false);
    manager = trnrun.SimulationManager(max_concurrent=4);
    cleanup = onCleanup(@() delete(manager));

    for index = 1:numel(files)
        deck_path = fullfile(files(index).folder, files(index).name);
        manager.add(deck_path, config);
    end

    manager.wait();
    manager.shutdown();
    simulations = manager.simulations;

    clear cleanup
end
