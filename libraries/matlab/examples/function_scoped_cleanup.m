function simulation = function_scoped_cleanup(deck_path)
%FUNCTION_SCOPED_CLEANUP Demonstrate deterministic cleanup around one run.

    library_path = fileparts(fileparts(mfilename("fullpath")));
    addpath(library_path)

    manager = trnrun.SimulationManager(max_concurrent=1);

    % Function scope guarantees this guard runs on return, error, or Ctrl+C.
    % delete() is a destructive fallback for unfinished owned work, whereas
    % shutdown() below is the normal drain-and-finish path.
    cleanup = onCleanup(@() delete(manager));

    config = trnrun.SimulationConfig(watch_tmp=false);
    simulation = manager.add(deck_path, config);
    manager.wait(simulation);
    manager.shutdown();

    fprintf("Succeeded: %d\n", simulation.succeeded);

    clear cleanup
end
