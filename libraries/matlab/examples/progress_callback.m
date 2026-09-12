function simulation = progress_callback(deck_path)
%PROGRESS_CALLBACK Print Type3830 progress with a short follow callback.
% The deck must contain a working, separately installed Type3830 component.

    library_path = fileparts(fileparts(mfilename("fullpath")));
    addpath(library_path)

    config = trnrun.SimulationConfig( ...
        watch_tmp=true, ...
        wait_for_tmp=true);
    manager = trnrun.SimulationManager( ...
        maxConcurrent=1, ...
        refreshInterval=0);
    cleanup = onCleanup(@() delete(manager));

    simulation = manager.add(deck_path, config);
    manager.follow(@print_update);
    manager.shutdown();

    clear cleanup
end

function print_update(updated)
% Keep callbacks short and never call manager methods from a callback.
    if ~isempty(updated.progress)
        fprintf("[%d] %6.1f%%, elapsed %.1f s, ETA %.1f s\n", ...
            updated.id, ...
            100 * updated.progress.percent, ...
            updated.progress.elapsed / 1000, ...
            updated.progress.eta / 1000);
    end
end
