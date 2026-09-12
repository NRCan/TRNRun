function manualQueueProcessTest()
    %MANUALQUEUEPROCESSTEST Run one basic QueueProcess smoke test without TRNSYS.
    %   Run manualQueueProcessTest from this folder in MATLAB on Windows.
    %   First build the fixture from PowerShell using buildFakeQueue.ps1
    %   in this folder.
    %
    %   Sends one request to fake_queue.exe, prints its three events, and
    %   checks successful completion and EOF. No real deck or runner is used.
    %   Ten seconds without stdout terminates the test queue. Cleanup also
    %   runs on failure or Ctrl+C.

    here = fileparts(mfilename('fullpath'));
    matlab_root = fileparts(fileparts(here));
    original_path = path;
    restore_path = onCleanup(@() path(original_path)); %#ok<NASGU>
    addpath(matlab_root);

    queue = trnrun.internal.QueueProcess(fullfile(here, 'build', 'fake_queue.exe'), 1);
    cleanup = onCleanup(@() delete(queue)); %#ok<NASGU>
    queue.send(struct( ...
        'runID', 'manual-test', ...
        'deckFile', 'normal.dck', ...
        'runnerPath', 'unused.exe', ...
        'runnerArgs', {{}}));
    queue.close();

    expected = ["ACCEPTED", "DONE", "COMPLETED"];
    for index = 1:numel(expected)
        line = queue.readLine(10);
        assert(ischar(line), 'Queue reached EOF before all three events.');
        fprintf('%s\n', line);
        event = jsondecode(line);
        assert(strcmp(event.runID, 'manual-test'), 'Unexpected run ID.');
        if index == 2
            assert(strcmp(event.kind, 'STATUS') && strcmp(event.status, expected(index)), ...
                'Expected runner status DONE.');
        else
            assert(strcmp(event.kind, 'QUEUE') && strcmp(event.event, expected(index)), ...
                'Unexpected queue event.');
        end
        if index == 3
            assert(event.exitCode == 0, 'The simulated runner failed.');
        end
    end

    line = queue.readLine(10);
    assert(isnumeric(line) && isempty(line), 'Expected EOF after completion.');
    exit_code = queue.wait();
    disp(queue.diagnostics());
    assert(exit_code == 0, 'Queue exited with code %g.', exit_code);
    fprintf('PASS: one request accepted, completed, and drained successfully.\n');
end
