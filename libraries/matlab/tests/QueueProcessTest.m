classdef QueueProcessTest < matlab.unittest.TestCase
    %QUEUEPROCESSTEST Unit tests for trnrun.internal.QueueProcess.
    %   These tests drive the real bundled queue executable, so they need
    %   Windows and toolbox/bin/trnrunq.exe, but never TRNSYS: every scenario
    %   ends either at a rejected request or at a forced cleanup.
    %
    %   A rejected request is the only queue reply reachable without TRNSYS.
    %   The queue reports it on stderr and exits with code 2.

    properties (Constant)
        % A request the queue parses but rejects, because deckFile is absent.
        RejectedRequest = struct('runID', '1')
        RejectedExitCode = 2
    end

    properties
        Executable (1,1) string
        Queues = {}
    end

    methods (TestClassSetup)
        function addToolbox(testCase)
            %ADDTOOLBOX Put the toolbox on the path for the whole class.

            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                toolboxFolder()));
        end

        function requireWindowsQueue(testCase)
            %REQUIREWINDOWSQUEUE Skip the class where the transport cannot run.

            testCase.assumeTrue(ispc, ...
                'The MATLAB client supports Windows only.');
            testCase.Executable = fullfile(toolboxFolder(), "bin", "trnrunq.exe");
            testCase.assumeTrue(isfile(testCase.Executable), ...
                'Build the queue executable before running these tests.');
        end
    end

    methods (TestMethodTeardown)
        function releaseQueues(testCase)
            %RELEASEQUEUES Terminate every queue started by the test.
            %   Live instances would also pin the class definition in memory.

            for index = 1:numel(testCase.Queues)
                queue = testCase.Queues{index};
                if isvalid(queue)
                    queue.forceCleanup();
                    delete(queue);
                end
            end
            testCase.Queues = {};
        end
    end

    methods (Test)
        % -----------------------------------------------------------------
        % Construction
        % -----------------------------------------------------------------

        function rejectsMissingExecutable(testCase)
            %REJECTSMISSINGEXECUTABLE Nothing is spawned for a path that is not a file.

            folder = fileparts(testCase.Executable);

            testCase.verifyError(@() trnrun.internal.QueueProcess( ...
                fullfile(folder, "absent.exe"), 1), 'MATLAB:validators:mustBeFile');
            testCase.verifyError(@() trnrun.internal.QueueProcess(folder, 1), ...
                'MATLAB:validators:mustBeFile');
        end

        function rejectsInvalidConcurrency(testCase)
            %REJECTSINVALIDCONCURRENCY Concurrency is a positive whole number.

            testCase.verifyError(@() trnrun.internal.QueueProcess( ...
                testCase.Executable, 0), 'MATLAB:validators:mustBePositive');
            testCase.verifyError(@() trnrun.internal.QueueProcess( ...
                testCase.Executable, -2), 'MATLAB:validators:mustBePositive');
            testCase.verifyError(@() trnrun.internal.QueueProcess( ...
                testCase.Executable, 1.5), 'MATLAB:validators:mustBeInteger');
        end

        function startsProcessAndReportsIdentity(testCase)
            %STARTSPROCESSANDREPORTSIDENTITY A live queue has a PID and no exit code.

            queue = testCase.startQueue(2);
            details = queue.diagnostics();

            testCase.verifyGreaterThan(details.pid, 0);
            testCase.verifyEmpty(details.exit_code);
            testCase.verifyEmpty(details.stderr);
            testCase.verifyEqual(details.stderr_dropped, 0);
        end

        function acceptsRelativeExecutablePath(testCase)
            %ACCEPTSRELATIVEEXECUTABLEPATH The path is resolved before spawning.

            folder = fileparts(testCase.Executable);
            testCase.applyFixture( ...
                matlab.unittest.fixtures.CurrentFolderFixture(folder));

            queue = testCase.startQueue(1, "trnrunq.exe");

            testCase.verifyGreaterThan(queue.diagnostics().pid, 0);
        end

        % -----------------------------------------------------------------
        % Request and reply
        % -----------------------------------------------------------------

        function rejectedRequestReachesTheQueueAndIsReportedOnStderr(testCase)
            %REJECTEDREQUESTREACHESTHEQUEUEANDISREPORTEDONSTDERR The pipes carry both ways.

            queue = testCase.startQueue(1);
            queue.send(testCase.RejectedRequest);

            testCase.verifyEmpty(queue.readLine(30), ...
                'A rejected request produces no stdout before EOF.');
            testCase.verifyEqual(queue.wait(), testCase.RejectedExitCode);

            details = queue.diagnostics();
            testCase.verifyEqual(details.exit_code, testCase.RejectedExitCode);
            testCase.verifyNotEmpty(details.stderr);
            testCase.verifySubstring(details.stderr{1}, 'deckFile');
            testCase.verifyEqual(details.stderr_dropped, 0);
        end

        function readLineReturnsNumericEmptyAtEof(testCase)
            %READLINERETURNSNUMERICEMPTYATEOF EOF is numeric [], not an empty char row.

            queue = testCase.startQueue(1);
            queue.close();
            line = queue.readLine(30);

            testCase.verifyTrue(isnumeric(line) && isempty(line));
        end

        function repeatedReadsAtEofStayAtEof(testCase)
            %REPEATEDREADSATEOFSTAYATEOF Draining a closed queue is idempotent.

            queue = testCase.startQueue(1);
            queue.close();
            testCase.assertEmpty(queue.readLine(30));

            testCase.verifyEmpty(queue.readLine(30));
            testCase.verifyEmpty(queue.readLine(30));
        end

        function sendRejectsNonStructRequests(testCase)
            %SENDREJECTSNONSTRUCTREQUESTS Requests are JSON objects.

            queue = testCase.startQueue(1);

            testCase.verifyError(@() queue.send('{"runID":"1"}'), ...
                'MATLAB:validation:UnableToConvert');
            testCase.verifyError(@() queue.send( ...
                [struct('runID', '1'), struct('runID', '2')]), ...
                'MATLAB:validation:IncompatibleSize');
        end

        % -----------------------------------------------------------------
        % Timeout
        % -----------------------------------------------------------------

        function readTimeoutTerminatesTheQueue(testCase)
            %READTIMEOUTTERMINATESTHEQUEUE An expired read is not resumable.

            queue = testCase.startQueue(1);

            testCase.verifyError(@() queue.readLine(0.25), ...
                'trnrun:QueueReadTimeout');
            testCase.verifyNotEmpty(queue.diagnostics().exit_code, ...
                'The queue must be terminated, not left running.');
        end

        function readTimeoutRejectsNonPositiveValues(testCase)
            %READTIMEOUTREJECTSNONPOSITIVEVALUES A zero timeout could never succeed.

            queue = testCase.startQueue(1);

            testCase.verifyError(@() queue.readLine(0), ...
                'MATLAB:validators:mustBePositive');
            testCase.verifyError(@() queue.readLine(-1), ...
                'MATLAB:validators:mustBePositive');
        end

        function readWithoutTimeoutWaitsIndefinitely(testCase)
            %READWITHOUTTIMEOUTWAITSINDEFINITELY The default timeout is Inf, not zero.

            queue = testCase.startQueue(1);
            queue.close();

            testCase.verifyEmpty(queue.readLine(), ...
                'Closing input must let the default read reach EOF.');
        end

        % -----------------------------------------------------------------
        % Shutdown
        % -----------------------------------------------------------------

        function closeEndsSubmissionAndIsRepeatable(testCase)
            %CLOSEENDSSUBMISSIONANDISREPEATABLE Closing twice is harmless.

            queue = testCase.startQueue(1);
            queue.close();
            queue.close();

            testCase.verifyError(@() queue.send(testCase.RejectedRequest), ...
                'trnrun:QueueInputClosed');
        end

        function waitDrainsClosesAndReturnsZeroForAnIdleQueue(testCase)
            %WAITDRAINSCLOSESANDRETURNSZEROFORANIDLEQUEUE An unused queue exits cleanly.

            queue = testCase.startQueue(1);

            testCase.verifyEqual(queue.wait(), 0);
        end

        function waitIsIdempotentAndCachesTheExitCode(testCase)
            %WAITISIDEMPOTENTANDCACHESTHEEXITCODE Reaping happens exactly once.

            queue = testCase.startQueue(1);
            first = queue.wait();

            testCase.verifyEqual(queue.wait(), first);
            testCase.verifyEqual(queue.diagnostics().exit_code, first);
        end

        function waitClosesInputImplicitly(testCase)
            %WAITCLOSESINPUTIMPLICITLY No submission survives a completed wait.

            queue = testCase.startQueue(1);
            queue.wait();

            testCase.verifyError(@() queue.send(testCase.RejectedRequest), ...
                'trnrun:QueueInputClosed');
        end

        function forceCleanupTerminatesAndIsRepeatable(testCase)
            %FORCECLEANUPTERMINATESANDISREPEATABLE Cleanup tolerates being called twice.

            queue = testCase.startQueue(1);
            queue.forceCleanup();
            details = queue.diagnostics();

            testCase.verifyNotEmpty(details.exit_code);
            testCase.verifyNotEqual(details.exit_code, 0, ...
                'A killed queue does not exit successfully.');

            queue.forceCleanup();
            testCase.verifyEqual(queue.diagnostics().exit_code, details.exit_code);
        end

        function waitAfterForceCleanupReturnsTheCachedCode(testCase)
            %WAITAFTERFORCECLEANUPRETURNSTHECACHEDCODE A disposed queue is not re-reaped.

            queue = testCase.startQueue(1);
            queue.forceCleanup();
            expected = queue.diagnostics().exit_code;

            testCase.verifyEqual(queue.wait(), expected);
        end

        function deleteTerminatesTheQueue(testCase)
            %DELETETERMINATESTHEQUEUE Losing the handle must not leak a process.

            queue = trnrun.internal.QueueProcess(testCase.Executable, 1);
            pid = queue.diagnostics().pid;

            delete(queue);

            testCase.verifyFalse(isvalid(queue));
            testCase.verifyFalse(testCase.processIsRunning(pid));
        end

        function diagnosticsSurviveDisposal(testCase)
            %DIAGNOSTICSSURVIVEDISPOSAL Failure reporting outlives the process handles.

            queue = testCase.startQueue(1);
            queue.send(testCase.RejectedRequest);
            queue.wait();

            details = queue.diagnostics();

            testCase.verifyGreaterThan(details.pid, 0);
            testCase.verifyEqual(details.exit_code, testCase.RejectedExitCode);
            testCase.verifyClass(details.stderr, 'cell');
            testCase.verifyNotEmpty(details.stderr);
        end
    end

    methods (Access = private)
        function queue = startQueue(testCase, maxConcurrent, executable)
            %STARTQUEUE Start a queue that is terminated when the test ends.

            if nargin < 3
                executable = testCase.Executable;
            end
            queue = trnrun.internal.QueueProcess(executable, maxConcurrent);
            testCase.Queues{end + 1} = queue;
        end

        function tf = processIsRunning(~, pid)
            %PROCESSISRUNNING Ask Windows whether a process ID is still alive.

            [status, output] = system(sprintf( ...
                'tasklist /FI "PID eq %d" /NH', pid));
            tf = status == 0 && contains(output, sprintf('%d', pid));
        end
    end
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the toolbox folder next to this tests folder.

    folder = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox');
end
