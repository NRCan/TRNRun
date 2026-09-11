classdef TestQueueProcess < matlab.unittest.TestCase
    properties
        queue_path
    end

    methods (TestMethodSetup)
        function requireBuiltFixtures(testCase)
            matlab_root = fileparts(fileparts(fileparts(mfilename('fullpath'))));
            testCase.queue_path = fullfile(fileparts(mfilename('fullpath')), ...
                'build', 'fake_queue.exe');
            helper = fullfile(matlab_root, 'bin', 'win64', 'TrnRun.Interop.dll');
            testCase.assumeTrue(ispc, 'Transport tests require Windows.');
            testCase.assumeTrue(isfile(testCase.queue_path), ...
                'Run buildFakeQueue.ps1 before transport tests.');
            testCase.assumeTrue(isfile(helper), ...
                'Run the interop build before transport tests.');
        end
    end

    methods (Test)
        function preservesUnicodeAndGracefulEof(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('unicode-路径.dck'));

            [~, accepted] = trnrun.internal.parseStreamLine(process.read_line(), "event");
            [~, status] = trnrun.internal.parseStreamLine(process.read_line(), "event");
            [~, completed] = trnrun.internal.parseStreamLine(process.read_line(), "event");
            testCase.verifyEqual(accepted.event, 'ACCEPTED');
            testCase.verifyEqual(status.message, 'terminé — ΔT');
            testCase.verifyEqual(completed.event, 'COMPLETED');

            process.close();
            testCase.verifyEmpty(process.read_line());
            testCase.verifyEqual(process.wait(), 0);
        end

        function drainsLargeStdoutAndStderrWithoutDeadlock(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 2);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('flood.dck'));

            count = 0;
            while true
                line = process.read_line();
                testCase.assertNotEmpty(line);
                [~, event] = trnrun.internal.parseStreamLine(line, "event");
                count = count + 1;
                if strcmp(event.kind, 'QUEUE') && strcmp(event.event, 'COMPLETED')
                    break
                end
            end
            testCase.verifyEqual(count, 5002);
            details = process.diagnostics();
            testCase.verifyEqual(numel(details.stderr), 200);
            testCase.verifyGreaterThan(details.stderr_dropped, 0);
            process.close();
            testCase.verifyEmpty(process.read_line());
            testCase.verifyEqual(process.wait(), 0);
        end

        function writeCompletionIsNotAcceptance(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('blocked.dck'));
            started = tic;
            [~, accepted] = trnrun.internal.parseStreamLine(process.read_line(), "event");
            testCase.verifyGreaterThanOrEqual(toc(started), 1.0);
            testCase.verifyEqual(accepted.event, 'ACCEPTED');
            process.read_line();
            process.read_line();
            process.close();
            process.read_line();
            process.wait();
        end

        function reportsCrashExitAndStderr(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('crash.dck'));
            testCase.verifyEmpty(process.read_line());
            process.close();
            testCase.verifyEqual(process.wait(), 7);
            details = process.diagnostics();
            testCase.verifyTrue(any(contains(details.stderr, 'intentional queue crash')));
        end

        function forceCleanupTerminatesOwnedProcessTree(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            process.send(request('tree.dck'));
            process.read_line();
            child_line = jsondecode(process.read_line());
            details = process.diagnostics();
            queue_pid = details.pid;
            child_pid = double(child_line.childPid);
            testCase.verifyTrue(process_exists(queue_pid));
            testCase.verifyTrue(process_exists(child_pid));

            process.force_cleanup();
            pause(0.25);
            testCase.verifyFalse(process_exists(queue_pid));
            testCase.verifyFalse(process_exists(child_pid));
        end
    end
end

function value = request(deck)
value = struct( ...
    'runID', 'transport-test', ...
    'deckFile', deck, ...
    'runnerPath', 'unused.exe', ...
    'runnerArgs', {{'--unicode:é'}});
end

function value = process_exists(pid)
value = false;
try
    process = System.Diagnostics.Process.GetProcessById(int32(pid));
    cleanup = onCleanup(@() process.Dispose()); %#ok<NASGU>
    value = ~process.HasExited;
catch
end
end
