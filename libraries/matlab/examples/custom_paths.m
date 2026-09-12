function simulation = custom_paths( ...
    deck_path, trnexe_path, trnrun_path, trnrunq_path)
%CUSTOM_PATHS Run a deck with explicit TRNSYS and native executable paths.

    library_path = fileparts(fileparts(mfilename("fullpath")));
    addpath(library_path)

    config = trnrun.SimulationConfig( ...
        trnexe_path=trnexe_path, ...
        trnrun_path=trnrun_path, ...
        watch_tmp=false);
    manager = trnrun.SimulationManager( ...
        maxConcurrent=1, ...
        trnrunqPath=trnrunq_path);
    cleanup = onCleanup(@() delete(manager));

    simulation = manager.add(deck_path, config);
    manager.wait();
    manager.shutdown();

    clear cleanup
end
