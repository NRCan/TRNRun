classdef TestQueueProcess < matlab.unittest.TestCase
    properties
        queue_path
    end

    methods (TestMethodSetup)
        function requireBuiltFixtures(testCase)

            testCase.queue_path = fullfile(fileparts(mfilename('fullpath')), ...
                'build', 'fake_queue.exe');

            testCase.assumeTrue(ispc, 'Transport tests require Windows.');
            testCase.assumeTrue(isfile(testCase.queue_path), ...
                'Run buildFakeQueue.ps1 before transport tests.');

        end
    end

    methods (Test)
        function preservesUnicodeAndGracefulEof(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            value = request('unicode-路径.dck');
            value.runID = 'transport-é-路径-Δ';
            process.send(value);

            [~, accepted] = trnrun.internal.parseStreamLine(process.readLine());
            [~, status] = trnrun.internal.parseStreamLine(process.readLine());
            [~, completed] = trnrun.internal.parseStreamLine(process.readLine());
            testCase.verifyEqual(accepted.event, 'ACCEPTED');
            testCase.verifyEqual(accepted.runID, string(value.runID));
            testCase.verifyEqual(status.message, 'terminé — ΔT');
            testCase.verifyEqual(completed.event, 'COMPLETED');
            testCase.verifyEqual(completed.runID, string(value.runID));

            process.close();
            testCase.verifyEmpty(process.readLine());
            testCase.verifyEqual(process.wait(), 0);
        end

        function rejectsInvalidConcurrencyWithNativeValidation(testCase)
            invalid = {0, -1, 1.5, NaN, Inf, [1 2], []};
            for index = 1:numel(invalid)
                exception = capture_exception(@() construct_and_delete( ...
                    testCase.queue_path, invalid{index}));
                testCase.assertNotEmpty(exception);
                testCase.verifyTrue(startsWith(exception.identifier, 'MATLAB:'), ...
                    exception.identifier);
            end
        end

        function sendsScalarStructWithoutEnforcingQueueSchema(testCase)
            process = trnrun.internal.QueueProcess(string(testCase.queue_path), 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            % The fixture needs only these fields; runner schema belongs to the queue.
            value = struct('runID', 'minimal-request', 'deckFile', 'normal.dck');
            process.send(value);
            testCase.verifyEqual(process.wait(), 0);
            accepted = jsondecode(process.readLine());
            testCase.verifyEqual(accepted.event, 'ACCEPTED');
            testCase.verifyEqual(accepted.runID, value.runID);
            process.readLine();
            completed = jsondecode(process.readLine());
            testCase.verifyEqual(completed.event, 'COMPLETED');
            testCase.verifyEqual(process.readLine(), []);
        end

        function rejectsNonScalarStructRequestsWithoutClosingInput(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            value = request('normal.dck');
            invalid = {'not a struct', {value}, repmat(value, 1, 2), repmat(value, 0, 0)};
            for index = 1:numel(invalid)
                testCase.verifyNotEmpty(capture_exception(@() process.send(invalid{index})));
            end
            process.send(value);
            testCase.verifyEqual(process.wait(), 0);
            accepted = jsondecode(process.readLine());
            testCase.verifyEqual(accepted.event, 'ACCEPTED');
        end

        function closeAndWaitRejectFurtherSends(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            before = process.diagnostics();
            testCase.assertGreaterThan(before.pid, 0);
            process.close();
            process.close();
            testCase.verifyError(@() process.send(request('normal.dck')), ...
                'trnrun:QueueInputClosed');
            testCase.verifyEqual(process.wait(), 0);
            testCase.verifyEqual(process.wait(), 0);
            process.close();
            testCase.verifyError(@() process.send(request('normal.dck')), ...
                'trnrun:QueueInputClosed');
            after = process.diagnostics();
            testCase.verifyEqual(after.pid, before.pid);
            testCase.verifyEqual(after.exit_code, 0);
            testCase.verifyEqual(process.readLine(), []);
            testCase.verifyEqual(process.readLine(), []);
        end

        function readTimeoutTerminatesTransport(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            before = process.diagnostics();
            started = tic;
            testCase.verifyError(@() process.readLine(0.05), ...
                'trnrun:QueueReadTimeout');
            testCase.verifyGreaterThanOrEqual(toc(started), 0.05);
            after = process.diagnostics();
            testCase.verifyEqual(after.pid, before.pid);
            testCase.verifyNotEmpty(after.exit_code);
            testCase.verifyFalse(process_exists(before.pid));
            testCase.verifyError(@() process.send(request('normal.dck')), ...
                'trnrun:QueueInputClosed');
            testCase.verifyEqual(process.readLine(10), []);
            testCase.verifyEqual(process.wait(), after.exit_code);
        end

        function bufferedBlankLinesRemainDistinctFromEof(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('blank.dck'));
            testCase.verifyEqual(process.wait(), 0);

            accepted = jsondecode(process.readLine(eps));
            testCase.verifyEqual(accepted.event, 'ACCEPTED');
            blank = process.readLine(eps);
            testCase.verifyClass(blank, 'char');
            testCase.verifyEqual(blank, '');
            status = jsondecode(process.readLine(eps));
            testCase.verifyEqual(status.kind, 'STATUS');
            completed = jsondecode(process.readLine(eps));
            testCase.verifyEqual(completed.event, 'COMPLETED');
            testCase.verifyEqual(process.readLine(eps), []);
        end

        function readTimeoutRejectsInvalidValues(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.wait();
            for value = {0, -1, NaN, -Inf, [1 2], []}
                testCase.verifyNotEmpty(capture_exception( ...
                    @() process.readLine(value{1})));
            end
            testCase.verifyEqual(process.readLine(Inf), []);
        end

        function waitPreservesFloodOutputAndDrainsBothStreams(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 2);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('flood.dck'));
            testCase.verifyEqual(process.wait(), 0);
            testCase.verifyEqual(process.wait(), 0);

            accepted = jsondecode(process.readLine());
            testCase.verifyEqual(accepted.event, 'ACCEPTED');
            for index = 0:4999
                event = jsondecode(process.readLine());
                testCase.verifyEqual(event.kind, 'LOG');
                testCase.verifyEqual(event.messageCode, index);
                testCase.verifyEqual(event.message, 'débit élevé');
            end
            completed = jsondecode(process.readLine());
            testCase.verifyEqual(completed.event, 'COMPLETED');
            testCase.verifyEqual(process.readLine(), []);
            testCase.verifyEqual(process.readLine(), []);
            details = process.diagnostics();
            testCase.verifySize(details, [1 1]);
            testCase.verifyClass(details.stderr, 'cell');
            testCase.verifySize(details.stderr, [1 200]);
            testCase.verifyTrue(all(cellfun(@ischar, details.stderr)));
            testCase.verifyEqual(details.stderr_dropped, 4800);
            testCase.verifyEqual(details.stderr{1}, 'stderr-4800-é');
            testCase.verifyEqual(details.stderr{end}, 'stderr-4999-é');
        end

        function truncatesStderrWithoutSplittingSurrogatePairs(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('long-stderr.dck'));
            testCase.verifyEqual(process.wait(), 0);

            details = process.diagnostics();
            testCase.verifyEqual(details.stderr, { ...
                repmat('a', 1, 1000), ...
                repmat('b', 1, 999), ...
                [repmat('c', 1, 998) char([55357 56832])], ...
                '', 'after truncation'});
            testCase.verifyEqual(details.stderr_dropped, 0);
        end

        function drainsLargeStdoutAndStderrWithoutDeadlock(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 2);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('flood.dck'));

            count = 0;
            while true
                line = process.readLine();
                testCase.assertNotEmpty(line);
                [~, event] = trnrun.internal.parseStreamLine(line);
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
            testCase.verifyEmpty(process.readLine());
            testCase.verifyEqual(process.wait(), 0);
        end

        function writeCompletionIsNotAcceptance(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            process.send(request('blocked.dck'));
            started = tic;
            [~, accepted] = trnrun.internal.parseStreamLine(process.readLine());
            testCase.verifyGreaterThanOrEqual(toc(started), 1.0);
            testCase.verifyEqual(accepted.event, 'ACCEPTED');
            process.readLine();
            process.readLine();
            process.close();
            process.readLine();
            process.wait();
        end

        function reportsCrashExitAndStderr(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            before = process.diagnostics();
            process.send(request('crash.dck'));
            testCase.verifyEqual(process.readLine(), []);
            process.close();
            testCase.verifyEqual(process.wait(), 7);
            testCase.verifyEqual(process.wait(), 7);
            testCase.verifyError(@() process.send(request('normal.dck')), ...
                'trnrun:QueueInputClosed');
            details = process.diagnostics();
            testCase.verifyEqual(details.pid, before.pid);
            testCase.verifyEqual(details.exit_code, 7);
            testCase.verifyTrue(any(strcmp(details.stderr, 'intentional queue crash — échec')));
            testCase.verifyEqual(process.readLine(), []);
        end

        function forceCleanupTerminatesQueue(testCase)
            process = trnrun.internal.QueueProcess(testCase.queue_path, 1);
            cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
            details = process.diagnostics();
            queue_pid = details.pid;
            testCase.verifyTrue(process_exists(queue_pid));

            process.forceCleanup();
            process.forceCleanup();
            testCase.verifyError(@() process.send(request('normal.dck')), ...
                'trnrun:QueueInputClosed');
            pause(0.25);
            testCase.verifyFalse(process_exists(queue_pid));

        end
    end
end

function exception = capture_exception(action)
exception = [];
try
    action();
catch caught
    exception = caught;
end
end

function construct_and_delete(executable, max_concurrent)
process = trnrun.internal.QueueProcess(executable, max_concurrent);
cleanup = onCleanup(@() delete(process)); %#ok<NASGU>
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
