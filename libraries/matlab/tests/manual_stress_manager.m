function status = manual_stress_manager()
%MANUAL_STRESS_MANAGER Manual stress test: fast and slow simulations without plots, with tracking.
%   STATUS = MANUAL_STRESS_MANAGER() runs 50 fast and 50 slow deck copies,
%   25 at a time, through one trnrun.SimulationManager, and returns 0 if
%   every run succeeded, 1 otherwise.
%
%   Requires TRNSYS, Type3830, and toolbox/bin/trnrund.exe and trnrun.exe.
%   The slow deck also requires its referenced TRNSYS weather file. Edit the
%   configuration below for your installation. Deck copies and outputs are
%   retained in tests/runs for inspection. It is a plain function, not a
%   test, so buildtool test does not run it.

    here = string(fileparts(mfilename("fullpath")));
    addpath(fullfile(here, "..", "toolbox"))

    % -------------------------------------------------------------------------
    % Configuration
    % -------------------------------------------------------------------------
    decks = fullfile(here, "..", "..", "..", "decks");

    trnexe_path = "C:\TRNSYS18\Exe\TrnEXE64.exe";
    fast_dck = fullfile(decks, "fast_wo_plot_w_tracking.dck");
    slow_dck = fullfile(decks, "slow_wo_plot_w_tracking.dck");
    dck_folder = fullfile(here, "runs");

    fast_sim_count = 50;
    slow_sim_count = 50;
    workers = 25;
    poll_interval = 0.1;

    settings = trnrun.SimulationSettings(trnexePath=trnexe_path, watchTmp=true);

    % -------------------------------------------------------------------------
    % Run
    % -------------------------------------------------------------------------
    for source = [trnexe_path, fast_dck, slow_dck]
        if ~isfile(source)
            error("trnrun:FileNotFound", "File not found: %s", source);
        end
    end

    dck_files = [copy_dck(fast_dck, dck_folder, fast_sim_count), ...
        copy_dck(slow_dck, dck_folder, slow_sim_count)];

    fprintf("Running %d fast + %d slow simulations (workers: %d).\n", ...
        fast_sim_count, slow_sim_count, workers);

    started = tic;
    manager = trnrun.SimulationManager(workers=workers, pollInterval=poll_interval);
    for dck = dck_files
        manager.add(dck, settings);
    end
    manager.wait();
    simulations = manager.simulations;
    delete(manager);  % close trnrund; the simulations stay readable
    elapsed = toc(started);

    failed = simulations(~[simulations.succeeded]);
    fprintf("Finished in %.1fs: %d/%d succeeded, %d failed.\n", elapsed, ...
        numel(dck_files) - numel(failed), numel(dck_files), numel(failed));

    for sim = failed
        [~, name, extension] = fileparts(sim.deckFile);
        detail = sim.error;
        if ismissing(detail) || detail == ""
            detail = sim.trnrunMessage;
        end
        fprintf("FAILED %s%s: status=%s, error=%s\n", name, extension, ...
            sim.trnrunStatus, detail);
    end

    status = double(~isempty(failed));
end

function dck_files = copy_dck(src, dst_dir, n)
%COPY_DCK Copy SRC into DST_DIR N times with unique, zero-padded names for independent outputs.

    if ~isfolder(dst_dir)
        mkdir(dst_dir);
    end

    [~, stem, extension] = fileparts(src);

    dck_files = strings(1, n);
    for index = 1:n
        dck_files(index) = fullfile(dst_dir, ...
            sprintf("%s_%04d%s", stem, index, extension));
        copyfile(src, dck_files(index));
    end
end
