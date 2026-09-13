function exit_code = manual_stress_manager()
%MANUAL_STRESS_MANAGER Stress-test fast and slow tracked simulations.
%   EXIT_CODE = MANUAL_STRESS_MANAGER() copies fast and slow deck fixtures,
%   submits them through one TRNRun manager, and returns zero only when every
%   simulation succeeds.
%
%   Run from libraries/matlab with:
%
%       matlab -batch "addpath('tests'); exit(manual_stress_manager())"
%
%   This test requires TRNSYS, Type3830, and the bundled TRNRun and queue
%   executables. The slow fixture also requires its referenced TRNSYS weather
%   file. Edit the configuration below for your installation. Deck copies and
%   outputs are retained directly in tests/runs for inspection.

    tests_folder = string(fileparts(mfilename("fullpath")));
    matlab_folder = fileparts(tests_folder);
    addpath(fullfile(matlab_folder, "toolbox"));
    import trnrun.*

    % -------------------------------------------------------------------------
    % Configuration
    % -------------------------------------------------------------------------
    trnexe_path = "C:\TRNSYS18\Exe\TrnEXE64.exe";
    fast_dck = fullfile(tests_folder, "dck", ...
        "test_fast_wo_plot_w_tracking.dck");
    slow_dck = fullfile(tests_folder, "dck", ...
        "test_slow_wo_plot_w_tracking.dck");
    dck_folder = fullfile(tests_folder, "runs");

    fast_sim_count = 1;
    slow_sim_count = 20;
    max_concurrent = 10;
    refresh_interval = 0.1;

    config = SimulationConfig( ...
        trnexe_path=trnexe_path, ...
        watch_tmp=true);

    % -------------------------------------------------------------------------
    % Prepare workload
    % -------------------------------------------------------------------------
    config = config.validate();

    sources = [fast_dck, slow_dck];
    for source = sources
        if ~isfile(source)
            error("trnrun:DeckNotFound", "Deck file not found: %s", source);
        end
    end

    if ~isfolder(dck_folder)
        mkdir(dck_folder);
    end

    fprintf("Decks and outputs: %s\n", dck_folder);

    dck_files = copy_dck(fast_dck, dck_folder, fast_sim_count);
    dck_files = [dck_files, ...
        copy_dck(slow_dck, dck_folder, slow_sim_count)];

    fprintf("Running %d fast + %d slow simulations (concurrency: %d).\n", ...
        fast_sim_count, slow_sim_count, max_concurrent);

    % -------------------------------------------------------------------------
    % Run
    % -------------------------------------------------------------------------
    started = tic;
    manager = SimulationManager( ...
        maxConcurrent=max_concurrent, ...
        refreshInterval=refresh_interval);

    for dck = dck_files
        manager.add(dck, config);
    end

    manager.wait();
    manager.shutdown();
    elapsed = toc(started);

    succeeded = manager.succeeded;
    failed = manager.failed;

    fprintf("Finished in %.1fs: %d/%d succeeded, %d failed.\n", ...
        elapsed, numel(succeeded), numel(dck_files), numel(failed));

    for simulation = failed
        fprintf("FAILED %s: status=%s, completion=%s\n", ...
            deck_name(simulation.deckPath), ...
            event_json(simulation.status), ...
            event_json(simulation.completionEvent));
    end

    exit_code = double(numel(succeeded) ~= numel(dck_files));
end

function dck_files = copy_dck(src, dst_dir, n)
%COPY_DCK Copy SRC N times with unique, zero-padded names.

    [~, stem, extension] = fileparts(src);
    dck_files = strings(1, n);

    for index = 1:n
        destination = fullfile(dst_dir, ...
            sprintf("%s_%04d%s", stem, index, extension));
        copyfile(src, destination, "f");
        dck_files(index) = destination;
    end
end

function name = deck_name(path)
%DECK_NAME Return the filename portion of a deck path.

    [~, stem, extension] = fileparts(path);
    name = stem + extension;
end

function text = event_json(event)
%EVENT_JSON Render an event struct for failure diagnostics.

    if isempty(event)
        text = "[]";
    else
        text = string(jsonencode(event));
    end
end
