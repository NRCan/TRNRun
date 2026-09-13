function simulations = example_manager()
%EXAMPLE_MANAGER Run multiple TRNSYS simulations with trnrun.SimulationManager.
%   SIMULATIONS = EXAMPLE_MANAGER() copies the bundled example deck several
%   times, submits every copy through one manager with bounded concurrency,
%   and returns the accepted simulations once they have all finished.

    example_folder = string(fileparts(mfilename("fullpath")));
    addpath(fileparts(example_folder))
    import trnrun.*

    % -------------------------------------------------------------------------
    % Configuration
    % -------------------------------------------------------------------------
    trnexe_path = "C:\TRNSYS18\Exe\TrnEXE64.exe";
    master_dck = fullfile(example_folder, "dck", "example_wo_plot_w_tracking.dck");
    dck_folder = fullfile(example_folder, "runs");

    sim_count = 20;
    max_concurrent = 10;
    refresh_interval = 1;

    config = SimulationConfig(trnexe_path=trnexe_path, watch_tmp=true);

    % -------------------------------------------------------------------------
    % Run
    % -------------------------------------------------------------------------
    dck_files = copy_dck(master_dck, dck_folder, sim_count);

    manager = SimulationManager(maxConcurrent=max_concurrent, refreshInterval=refresh_interval);

    for dck = dck_files
        manager.add(dck, config);
    end

    manager.wait();
    manager.shutdown();

    simulations = manager.simulations;

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
