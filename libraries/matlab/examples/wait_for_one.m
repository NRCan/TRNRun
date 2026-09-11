function [first, second] = wait_for_one(first_deck_path, second_deck_path)
%WAIT_FOR_ONE Wait for one run while the manager updates all accepted runs.

    library_path = fileparts(fileparts(mfilename("fullpath")));
    addpath(library_path)

    config = trnrun.SimulationConfig(watch_tmp=false);
    manager = trnrun.SimulationManager(max_concurrent=2);
    cleanup = onCleanup(@() delete(manager));

    first = manager.add(first_deck_path, config);
    second = manager.add(second_deck_path, config);

    manager.wait(first);
    fprintf("First run finished: %d\n", first.isFinished);
    fprintf("Second run finished: %d\n", second.isFinished);

    % Finish any work that remained active when the first run completed.
    manager.wait();
    manager.shutdown();

    clear cleanup
end
