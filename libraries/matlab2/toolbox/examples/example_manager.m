function simulations = example_manager()
%EXAMPLE_MANAGER Run copies of a deck, many at a time, with live progress.
%   SIMULATIONS = EXAMPLE_MANAGER() copies the bundled example deck ten
%   times, runs five at a time through one trnrun.SimulationManager, and
%   returns the simulations once they have all finished. Ctrl+C also
%   closes trnrund.

    example_folder = string(fileparts(mfilename("fullpath")));
    addpath(fileparts(example_folder))
    import trnrun.*

    % -------------------------------------------------------------------------
    % Configuration
    % -------------------------------------------------------------------------
    master_dck = fullfile(example_folder, "dck", "slow_wo_plot_w_tracking.dck");
    dck_folder = fullfile(example_folder, "runs");
    settings = SimulationSettings(trnexePath="C:\TRNSYS18\Exe\TrnEXE64.exe", watchTmp=true);

    % -------------------------------------------------------------------------
    % Run
    % -------------------------------------------------------------------------
    dck_files = copy_dck(master_dck, dck_folder, 10);

    manager = SimulationManager(workers=5, refreshInterval=0.1);
    for dck = dck_files
        manager.add(dck, settings, waitFor="RUNNING");
    end
    manager.wait();
    simulations = manager.simulations;
    delete(manager);  % close trnrund; the simulations stay readable

    failed = simulations(~[simulations.succeeded]);
    fprintf("%d/%d succeeded\n", numel(simulations) - numel(failed), numel(simulations));
    for sim = failed
        fprintf("  [%d] %s: %s %s\n", sim.simId, sim.deckFile, ...
            sim.trnrunStatus, sim.trnrunMessage);
    end
end

function dck_files = copy_dck(src, dst_dir, n)
%COPY_DCK Copy SRC into DST_DIR N times with a zero-padded suffix.

    if ~isfolder(dst_dir)
        mkdir(dst_dir);
    end

    [~, stem, extension] = fileparts(src);

    dck_files = strings(1, n);
    for index = 1:n
        dck_files(index) = fullfile(dst_dir, ...
            sprintf("%s_%03d%s", stem, index, extension));
        copyfile(src, dck_files(index));
    end
end
