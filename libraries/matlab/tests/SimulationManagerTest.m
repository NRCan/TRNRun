classdef SimulationManagerTest < matlab.unittest.TestCase
    %SIMULATIONMANAGERTEST Unit tests for trnrun.SimulationManager.
    %   The manager is exercised against a scripted transport rather than a
    %   real queue process. tests/testdoubles holds a stand-in for
    %   trnrun.internal.QueueProcess, and this class puts that folder ahead
    %   of the toolbox on the MATLAB path.
    %
    %   MATLAB keeps a loaded class definition while instances of it exist,
    %   so the shadow only takes hold once every real queue has been
    %   deleted. TestClassSetup asserts that it did; a failure there means a
    %   live trnrun.internal.QueueProcess is pinning the real definition.
    %
    %   Displays are disabled with refreshInterval=0 unless a test is about
    %   the display, so no progress windows open.

    properties
        Deck (1,1) string
        Config
        Manager
        Queue
    end

    methods (TestClassSetup)
        function shadowQueueProcess(testCase)
            %SHADOWQUEUEPROCESS Put the scripted transport ahead of the real one.

            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                {mockQueueFolder(), toolboxFolder()}));

            resolved = which('trnrun.internal.QueueProcess');
            testCase.assertEqual(string(resolved), ...
                string(fullfile(mockQueueFolder(), '+trnrun', '+internal', ...
                    'QueueProcess.m')), ...
                ['The scripted queue is not shadowing the real one. Delete ' ...
                 'every live trnrun.internal.QueueProcess, or run this test ' ...
                 'class in a fresh MATLAB session.']);
        end
    end

    methods (TestMethodSetup)
        function createInputs(testCase)
            %CREATEINPUTS Create a deck and executables that pass validation.

            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            testCase.Deck = fullfile(folder, "model.dck");
            runner = fullfile(folder, "trnrun.exe");
            trnexe = fullfile(folder, "TrnEXE64.exe");
            for path = [testCase.Deck, runner, trnexe]
                fid = fopen(path, 'w');
                fclose(fid);
            end
            testCase.Config = trnrun.SimulationConfig( ...
                trnrun_path=runner, trnexe_path=trnexe, watch_tmp=true);
        end
    end

    methods (TestMethodTeardown)
        function releaseManager(testCase)
            %RELEASEMANAGER Drop the manager and the appdata reference to its queue.

            testCase.Manager = [];
            testCase.Queue = [];
            if isappdata(0, 'TRNRunMockQueueProcess')
                rmappdata(0, 'TRNRunMockQueueProcess');
            end
        end
    end

    methods (Test)
        % -----------------------------------------------------------------
        % Construction
        % -----------------------------------------------------------------

        function constructorStartsQueueWithRequestedConcurrency(testCase)
            %CONSTRUCTORSTARTSQUEUEWITHREQUESTEDCONCURRENCY Options reach the transport.

            testCase.makeManager(maxConcurrent=4, trnrunqPath="custom-queue.exe");

            testCase.verifyEqual(testCase.Queue.maxConcurrent, 4);
            testCase.verifyEqual(testCase.Queue.executable, "custom-queue.exe");
        end

        function sourceDefaultQueuePathUsesDeployedExecutable(testCase)
            %SOURCEDEFAULTQUEUEPATHUSESDEPLOYEDEXECUTABLE Source tests use toolbox/bin.

            testCase.makeManager();
            expected = fullfile(toolboxFolder(), 'bin', 'trnrunq.exe');

            testCase.verifyEqual(testCase.Queue.executable, string(expected));
            testCase.verifyTrue(isfile(expected), ...
                'Native client deployment must stage the queue for source tests.');
        end

        function defaultConcurrencyReservesOneProcessor(testCase)
            %DEFAULTCONCURRENCYRESERVESONEPROCESSOR One logical processor stays free.
            %   MATLAB does not let SETENV override NUMBER_OF_PROCESSORS, so
            %   the expectation is recomputed from the real environment here
            %   rather than driven from fabricated values.

            processors = str2double(getenv('NUMBER_OF_PROCESSORS'));
            expected = 1;
            if isfinite(processors) && processors >= 2
                expected = floor(processors) - 1;
            end

            manager = trnrun.SimulationManager(refreshInterval=0);
            testCase.Manager = manager;
            testCase.Queue = getappdata(0, 'TRNRunMockQueueProcess');

            testCase.verifyEqual(testCase.Queue.maxConcurrent, expected);
            testCase.verifyGreaterThanOrEqual(testCase.Queue.maxConcurrent, 1, ...
                'At least one run must always be allowed.');
        end

        function constructorRejectsInvalidOptions(testCase)
            %CONSTRUCTORREJECTSINVALIDOPTIONS Concurrency and refresh are validated.

            testCase.verifyError(@() trnrun.SimulationManager(maxConcurrent=0), ...
                'MATLAB:validators:mustBePositive');
            testCase.verifyError(@() trnrun.SimulationManager(maxConcurrent=2.5), ...
                'MATLAB:validators:mustBeInteger');
            testCase.verifyError(@() trnrun.SimulationManager(refreshInterval=Inf), ...
                'MATLAB:validators:mustBeFinite');
            testCase.verifyError(@() trnrun.SimulationManager(refreshInterval=NaN), ...
                'MATLAB:validators:mustBeFinite');
        end

        function anIdleManagerHasNoSimulations(testCase)
            %ANIDLEMANAGERHASNOSIMULATIONS The result lists start empty, not unset.

            testCase.makeManager();

            testCase.verifyEmpty(testCase.Manager.simulations);
            testCase.verifyEmpty(testCase.Manager.submitted);
            testCase.verifyEmpty(testCase.Manager.active);
            testCase.verifyEmpty(testCase.Manager.succeeded);
            testCase.verifyEmpty(testCase.Manager.failed);
            testCase.verifyEmpty(testCase.Manager.sessionDiagnostics);
        end

        % -----------------------------------------------------------------
        % add
        % -----------------------------------------------------------------

        function addSendsOneRequestAndWaitsForAcceptance(testCase)
            %ADDSENDSONEREQUESTANDWAITSFORACCEPTANCE The wire request is fully specified.

            testCase.makeManager();
            testCase.Queue.queue(accepted(1));

            simulation = testCase.Manager.add(testCase.Deck, testCase.Config);

            testCase.verifyEqual(simulation.id, 1);
            testCase.verifyTrue(simulation.isAccepted);
            testCase.verifyEqual(simulation.deckPath, testCase.Deck);
            testCase.assertNumElements(testCase.Queue.sent, 1);
            request = testCase.Queue.sent{1};
            testCase.verifyEqual(request.runID, '1');
            testCase.verifyEqual(request.deckFile, char(testCase.Deck));
            testCase.verifyEqual(request.runnerPath, ...
                char(simulation.config.trnrun_path));
            testCase.verifyEqual(request.runnerArgs, simulation.config.to_cli_args());
        end


        function nonblockingAddReturnsPendingWithoutReading(testCase)
            testCase.makeManager();
            testCase.Queue.queue([accepted(1), accepted(2)]);
            mark = numel(testCase.Queue.calls);

            first = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            second = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);

            testCase.verifyEqual(testCase.Queue.callsSince(mark), ["send", "send"]);
            testCase.verifyEqual(string({testCase.Queue.sent{1}.runID, ...
                testCase.Queue.sent{2}.runID}), ["1", "2"]);
            testCase.verifyEqual([first.id, second.id], [1, 2]);
            testCase.verifyEqual(first.state, 'pending');
            testCase.verifyFalse(second.isAccepted);
            testCase.verifyTrue(first.isRunning);
            testCase.verifyEqual(testCase.Manager.submitted, [first, second]);
            testCase.verifyEqual(testCase.Manager.active, [first, second]);
            testCase.verifyEmpty(testCase.Manager.simulations);
            testCase.verifyEmpty(testCase.Manager.succeeded);
            testCase.verifyEmpty(testCase.Manager.failed);
        end

        function explicitBlockingAddStillWaitsForAcceptance(testCase)
            testCase.makeManager();
            testCase.Queue.queue(accepted(1));

            simulation = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=true);

            testCase.verifyTrue(simulation.isAccepted);
            testCase.verifyEqual(testCase.Queue.calls, ["send", "readLine"]);
        end

        function nonblockingSendFailureDiscardsHandleAndRetiresId(testCase)
            testCase.makeManager();
            testCase.Queue.sendError = "trnrun:QueuePipeFailed";

            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config, blocking=false), ...
                'trnrun:QueuePipeFailed');
            testCase.verifyEmpty(testCase.Manager.submitted);
            testCase.verifyEmpty(testCase.Manager.active);

            testCase.Queue.sendError = string(missing);
            simulation = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            testCase.verifyEqual(simulation.id, 2);
            testCase.verifyEqual(testCase.Manager.submitted, simulation);
        end

        function addAssignsIncreasingRunIds(testCase)
            %ADDASSIGNSINCREASINGRUNIDS Run IDs are unique within a session.

            testCase.makeManager();
            testCase.Queue.queue([accepted(1), accepted(2), accepted(3)]);

            ids = arrayfun(@(~) ...
                testCase.Manager.add(testCase.Deck, testCase.Config).id, 1:3);

            testCase.verifyEqual(ids, [1 2 3]);
        end

        function addRejectsMissingDeckAndExecutables(testCase)
            %ADDREJECTSMISSINGDECKANDEXECUTABLES Validation happens before any send.

            testCase.makeManager();
            folder = fileparts(testCase.Deck);
            brokenConfig = testCase.Config;
            brokenConfig.trnrun_path = fullfile(folder, "absent.exe");

            testCase.verifyError(@() testCase.Manager.add( ...
                fullfile(folder, "absent.dck"), testCase.Config), ...
                'MATLAB:validators:mustBeFile');
            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, brokenConfig), 'MATLAB:validators:mustBeFile');
            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, struct()), 'MATLAB:validation:UnableToConvert');

            testCase.verifyEmpty(testCase.Queue.sent);
            testCase.verifyEmpty(testCase.Manager.simulations);
        end

        function addDiscardsTheRunWhenTheSendFails(testCase)
            %ADDDISCARDSTHERUNWHENTHESENDFAILS A failed write must never reuse its ID.

            testCase.makeManager();
            testCase.Queue.sendError = "trnrun:QueuePipeFailed";

            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config), 'trnrun:QueuePipeFailed');
            testCase.verifyEmpty(testCase.Manager.simulations);

            testCase.Queue.sendError = string(missing);
            testCase.Queue.queue(accepted(2));
            simulation = testCase.Manager.add(testCase.Deck, testCase.Config);

            testCase.verifyEqual(simulation.id, 2, ...
                'The ID of a failed submission is retired.');
        end

        function addFoldsRunnerUpdatesReceivedBeforeAcceptance(testCase)
            %ADDFOLDSRUNNERUPDATESRECEIVEDBEFOREACCEPTANCE Early updates are not lost.

            testCase.makeManager();
            testCase.Queue.queue([ ...
                status(1, "RUNNING", "launched"), ...
                progress(1, 0.25), ...
                accepted(1)]);

            simulation = testCase.Manager.add(testCase.Deck, testCase.Config);

            testCase.verifyEqual(simulation.status.status, "RUNNING");
            testCase.verifyEqual(simulation.status.message, "launched");
            testCase.verifyEqual(simulation.progress.percent, 0.25);
        end

        function addIgnoresUnroutableAndMalformedOutput(testCase)
            %ADDIGNORESUNROUTABLEANDMALFORMEDOUTPUT Queue noise is recorded, not fatal.

            testCase.makeManager();
            testCase.Queue.queue([ ...
                "native diagnostic output", ...
                '{"runID":"1","kind":"STATUS"}', ...
                accepted(99), ...
                accepted(1)]);

            testCase.Manager.add(testCase.Deck, testCase.Config);
            diagnostics = testCase.Manager.sessionDiagnostics;

            testCase.verifyNumElements(diagnostics, 3);
            testCase.verifySubstring(diagnostics(1), 'unroutable queue output');
            testCase.verifySubstring(diagnostics(2), 'dropped malformed queue line');
            testCase.verifySubstring(diagnostics(3), 'unroutable queue output');
        end

        function addMatchesWireIdsExactly(testCase)
            %ADDMATCHESWIREIDSEXACTLY Numerically equal IDs are still different runs.

            testCase.makeManager();
            testCase.Queue.queue([ ...
                '{"runID":"01","kind":"QUEUE","event":"ACCEPTED","timestamp":"t"}', ...
                '{"runID":"1.0","kind":"QUEUE","event":"ACCEPTED","timestamp":"t"}', ...
                accepted(1)]);

            testCase.Manager.add(testCase.Deck, testCase.Config);

            testCase.verifyNumElements(testCase.Manager.sessionDiagnostics, 2);
        end

        function addReportsCompletionBeforeAcceptance(testCase)
            %ADDREPORTSCOMPLETIONBEFOREACCEPTANCE A skipped acceptance breaks the protocol.

            testCase.makeManager();
            testCase.Queue.queue(completed(1));

            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config), 'trnrun:QueueProtocolError');
        end

        function addReportsPrematureEofWithQueueStderr(testCase)
            %ADDREPORTSPREMATUREEOFWITHQUEUESTDERR A silent exit names the lost runs.

            testCase.makeManager();
            testCase.Queue.stderr = ["queue crashed", "at startup"];
            testCase.Queue.stderrDropped = 5;

            try
                testCase.Manager.add(testCase.Deck, testCase.Config);
                testCase.verifyFail('Expected a premature EOF error.');
            catch exception
                testCase.verifyEqual(exception.identifier, 'trnrun:PrematureQueueEOF');
                testCase.verifySubstring(exception.message, 'run IDs: 1');
                testCase.verifySubstring(exception.message, ...
                    '5 older stderr lines dropped');
                testCase.verifySubstring(exception.message, ...
                    'Queue stderr: queue crashed | at startup');
            end

            testCase.verifyEmpty(testCase.Manager.simulations, ...
                'Runs that were never accepted must not be reported.');
            testCase.verifyEmpty(testCase.Manager.failed, ...
                'Runs that were never accepted must not be classified as failed.');
        end

        function prematureEofToleratesUnavailableDiagnostics(testCase)
            %PREMATUREEOFTOLERATESUNAVAILABLEDIAGNOSTICS Optional detail never masks the error.

            testCase.makeManager();
            testCase.Queue.diagnosticsError = true;

            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config), 'trnrun:PrematureQueueEOF');
        end

        % -----------------------------------------------------------------
        % poll
        % -----------------------------------------------------------------

        function pollAppliesReadyUpdatesAcrossPendingRuns(testCase)
            testCase.makeManager();
            first = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            second = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            testCase.Queue.queue([ ...
                "native diagnostic output", ...
                status(1, "RUNNING"), ...
                accepted(2), ...
                accepted(1), ...
                accepted(1), ...
                status(1, "DONE"), completed(1), ...
                status(2, "ERROR"), completed(2), ...
                status(1, "ERROR")]);

            count = testCase.Manager.poll();

            testCase.verifyEqual(count, 7, ...
                'Only applied events, not noise or duplicate events, count.');
            testCase.verifyEqual(first.status.status, "DONE");
            testCase.verifyEqual(second.status.status, "ERROR");
            testCase.verifyTrue(first.isFinished);
            testCase.verifyTrue(second.isFinished);
            testCase.verifyEqual(testCase.Manager.submitted, [first, second]);
            testCase.verifyEmpty(testCase.Manager.active);
            testCase.verifyEqual(testCase.Manager.simulations, [first, second]);
            testCase.verifyEqual(testCase.Manager.succeeded, first);
            testCase.verifyEqual(testCase.Manager.failed, second);
            testCase.verifyNumElements(testCase.Manager.sessionDiagnostics, 3);
        end

        function pollConsumesUpdatesBeforeBlockingWait(testCase)
            testCase.makeManager();
            simulation = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            testCase.Queue.queue([accepted(1), progress(1, 0.5), ...
                status(1, "DONE"), completed(1)]);

            testCase.verifyEqual(testCase.Manager.poll(), 4);
            mark = numel(testCase.Queue.calls);
            testCase.Manager.wait(simulation);

            testCase.verifyEmpty(testCase.Queue.callsSince(mark));
            testCase.verifyEqual(simulation.progress.percent, 0.5);
            testCase.verifyTrue(simulation.succeeded);
        end

        function pollWithoutReadyUpdatesReturnsZero(testCase)
            testCase.makeManager();

            testCase.verifyEqual(testCase.Manager.poll(), 0);
            testCase.verifyEmpty(testCase.Manager.submitted);
            testCase.verifyEmpty(testCase.Manager.active);
        end

        function pollReturnsZeroWhenOutputIsNotYetReady(testCase)
            testCase.makeManager();
            testCase.Queue.pollNoReadyWhenEmpty = true;
            simulation = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);

            testCase.verifyEqual(testCase.Manager.poll(), 0);
            testCase.verifyEqual(testCase.Manager.active, simulation);
            testCase.verifyFalse(simulation.isAccepted);

            testCase.Queue.queue([accepted(1), completed(1)]);
            testCase.verifyEqual(testCase.Manager.poll(), 2);
            testCase.verifyTrue(simulation.isFinished);
        end

        function pollReportsCompletionBeforeAcceptance(testCase)
            testCase.makeManager();
            simulation = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            testCase.Queue.queue(completed(1));

            testCase.verifyError(@() testCase.Manager.poll(), ...
                'trnrun:QueueProtocolError');
            testCase.verifyTrue(simulation.isFinished);
            testCase.verifyFalse(simulation.isAccepted);
        end

        function pollReportsPrematureEofForPendingRuns(testCase)
            testCase.makeManager();
            first = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            second = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            testCase.Queue.stderr = "queue crashed";
            testCase.Queue.queue(accepted(2));

            try
                testCase.Manager.poll();
                testCase.verifyFail('Expected a premature EOF error.');
            catch exception
                testCase.verifyEqual(exception.identifier, 'trnrun:PrematureQueueEOF');
                testCase.verifySubstring(exception.message, 'run IDs: 1, 2');
                testCase.verifySubstring(exception.message, 'Queue stderr: queue crashed');
            end

            testCase.verifyFalse(first.isAccepted);
            testCase.verifyTrue(second.isAccepted);
            testCase.verifyEqual(testCase.Manager.active, [first, second]);
            testCase.verifyEqual(testCase.Manager.simulations, second);
            testCase.verifyEmpty(testCase.Manager.failed);
        end

        % -----------------------------------------------------------------
        % Routing
        % -----------------------------------------------------------------

        function duplicateAcceptanceIsRecordedNotApplied(testCase)
            %DUPLICATEACCEPTANCEISRECORDEDNOTAPPLIED A run is accepted at most once.

            simulation = testCase.addAccepted();
            testCase.Queue.queue([accepted(1), completed(1)]);

            testCase.Manager.wait(simulation);

            testCase.verifyTrue(any(contains( ...
                testCase.Manager.sessionDiagnostics, 'duplicate acceptance')));
        end

        function updatesAfterCompletionAreRecordedNotApplied(testCase)
            %UPDATESAFTERCOMPLETIONARERECORDEDNOTAPPLIED A finished run is frozen.

            simulation = testCase.addAccepted();
            testCase.Queue.queue([status(1, "DONE"), completed(1), ...
                status(1, "ERROR")]);

            testCase.Manager.wait(simulation);
            testCase.Manager.shutdown();

            testCase.verifyEqual(simulation.status.status, "DONE");
            testCase.verifyTrue(any(contains( ...
                testCase.Manager.sessionDiagnostics, 'update after completion')));
        end

        function unknownQueueEventsAreRecordedNotApplied(testCase)
            %UNKNOWNQUEUEEVENTSARERECORDEDNOTAPPLIED Only ACCEPTED and COMPLETED route.

            simulation = testCase.addAccepted();
            testCase.Queue.queue([queueEvent(1, "ENQUEUED"), completed(1)]);

            testCase.Manager.wait(simulation);

            testCase.verifyTrue(any(contains( ...
                testCase.Manager.sessionDiagnostics, 'unknown queue event')));
        end

        function diagnosticsAreCappedAtTwoHundredEntries(testCase)
            %DIAGNOSTICSARECAPPEDATTWOHUNDREDENTRIES Session history is bounded.

            testCase.makeManager();
            noise = arrayfun(@(index) sprintf('noise %d', index), 1:250, ...
                'UniformOutput', false);
            testCase.Queue.queue([string(noise), accepted(1)]);

            testCase.Manager.add(testCase.Deck, testCase.Config);
            diagnostics = testCase.Manager.sessionDiagnostics;

            testCase.verifyNumElements(diagnostics, 200);
            testCase.verifySubstring(diagnostics(1), 'noise 51');
            testCase.verifySubstring(diagnostics(end), 'noise 250');
        end

        function unexpectedParseErrorsPropagate(testCase)
            %UNEXPECTEDPARSEERRORSPROPAGATE Only event-parse failures are downgraded.

            testCase.makeManager();
            testCase.Queue.readError = "trnrun:QueueReadTimeout";

            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config), 'trnrun:QueueReadTimeout');
        end

        % -----------------------------------------------------------------
        % wait
        % -----------------------------------------------------------------

        function waitIncludesPendingNonblockingSubmissions(testCase)
            testCase.makeManager();
            first = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            second = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            testCase.Queue.queue([accepted(1), status(1, "DONE"), ...
                completed(1), accepted(2), completed(2)]);

            testCase.Manager.wait();

            testCase.verifyTrue(first.succeeded);
            testCase.verifyTrue(second.isFinished);
            testCase.verifyEqual(testCase.Manager.submitted, [first, second]);
            testCase.verifyEmpty(testCase.Manager.active);
            testCase.verifyEqual(testCase.Manager.failed, second);
        end

        function waitForOneRunStopsAtItsCompletion(testCase)
            %WAITFORONERUNSTOPSATITSCOMPLETION Later work stays queued for the next wait.

            first = testCase.addAccepted();
            second = testCase.addAccepted();
            testCase.Queue.queue([status(2, "RUNNING"), completed(1), completed(2)]);

            testCase.Manager.wait(first);

            testCase.verifyTrue(first.isFinished);
            testCase.verifyFalse(second.isFinished);
            testCase.verifyEqual(second.status.status, "RUNNING");
        end

        function waitForAFinishedRunReadsNothing(testCase)
            %WAITFORAFINISHEDRUNREADSNOTHING A completed target needs no queue traffic.

            simulation = testCase.addAccepted();
            testCase.Queue.queue(completed(1));
            testCase.Manager.wait(simulation);
            mark = numel(testCase.Queue.calls);

            testCase.Manager.wait(simulation);

            testCase.verifyEmpty(testCase.Queue.callsSince(mark));
        end

        function waitWithoutArgumentsDrainsEveryPendingRun(testCase)
            %WAITWITHOUTARGUMENTSDRAINSEVERYPENDINGRUN The default target is all runs.

            first = testCase.addAccepted();
            second = testCase.addAccepted();
            testCase.Queue.queue([completed(2), completed(1)]);

            testCase.Manager.wait();

            testCase.verifyTrue(first.isFinished);
            testCase.verifyTrue(second.isFinished);
        end

        function waitOnAnIdleManagerReturnsImmediately(testCase)
            %WAITONANIDLEMANAGERRETURNSIMMEDIATELY Nothing pending means nothing to read.

            testCase.makeManager();
            mark = numel(testCase.Queue.calls);

            testCase.Manager.wait();

            testCase.verifyEmpty(testCase.Queue.callsSince(mark));
        end

        function waitRejectsAForeignSimulation(testCase)
            %WAITREJECTSAFOREIGNSIMULATION Ownership is checked before reading.

            testCase.makeManager();
            outsider = trnrun.Simulation(testCase.Deck, testCase.Config, 1);
            mark = numel(testCase.Queue.calls);

            testCase.verifyError(@() testCase.Manager.wait(outsider), ...
                'trnrun:ForeignSimulation');
            testCase.verifyEmpty(testCase.Queue.callsSince(mark));
        end

        function waitRejectsNonScalarTargets(testCase)
            %WAITREJECTSNONSCALARTARGETS Wait takes one run or none.

            first = testCase.addAccepted();
            second = testCase.addAccepted();

            testCase.verifyError(@() testCase.Manager.wait([first, second]), ...
                'MATLAB:validators:mustBeScalarOrEmpty');
        end

        % -----------------------------------------------------------------
        % Reentrancy
        % -----------------------------------------------------------------

        function pollRejectsReentrantCalls(testCase)
            simulation = testCase.addAccepted();
            testCase.Queue.queue([progress(1, 0.5), completed(1)]);
            captured = MException.empty(1, 0);

            testCase.Queue.onRead = @capturePollError;
            testCase.Manager.poll();

            testCase.assertNumElements(captured, 1);
            testCase.verifyEqual(captured(1).identifier, ...
                'trnrun:ReentrantOperation');
            testCase.verifyTrue(simulation.isFinished);

            function capturePollError()
                if isempty(captured)
                    try
                        testCase.Manager.poll();
                    catch exception
                        captured(end + 1) = exception;
                    end
                end
            end
        end

        function operationsRejectReentrantCalls(testCase)
            %OPERATIONSREJECTREENTRANTCALLS Queue reads cannot re-enter the manager.

            simulation = testCase.addAccepted();
            testCase.Queue.queue([progress(1, 0.5), completed(1)]);
            manager = testCase.Manager;
            captured = MException.empty(1, 0);

            testCase.Queue.onRead = @captureError;
            testCase.Manager.wait(simulation);

            testCase.assertNumElements(captured, 1);
            testCase.verifyEqual(captured(1).identifier, 'trnrun:ReentrantOperation');
            testCase.verifyTrue(simulation.isFinished);

            function captureError()
                %CAPTUREERROR Call back into the manager and keep the failure.

                if isempty(captured)
                    try
                        manager.wait();
                    catch exception
                        captured(end + 1) = exception;
                    end
                end
            end
        end

        function theGuardIsClearedAfterAFailedOperation(testCase)
            %THEGUARDISCLEAREDAFTERAFAILEDOPERATION An error must not wedge the manager.

            testCase.makeManager();
            testCase.Queue.sendError = "trnrun:QueuePipeFailed";
            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config), 'trnrun:QueuePipeFailed');

            testCase.Queue.sendError = string(missing);
            testCase.Queue.queue(accepted(2));

            testCase.verifyWarningFree(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config));
        end

        % -----------------------------------------------------------------
        % Result lists
        % -----------------------------------------------------------------

        function activeExcludesCompletedRunsButSubmittedKeepsThem(testCase)
            testCase.makeManager();
            first = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            second = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            testCase.Queue.queue([accepted(1), status(1, "DONE"), ...
                completed(1), accepted(2), completed(2)]);

            testCase.Manager.wait(first);

            testCase.verifyEqual(testCase.Manager.submitted, [first, second]);
            testCase.verifyEqual(testCase.Manager.active, second);
            testCase.verifyFalse(second.isFinished);
            testCase.Manager.wait(second);
            testCase.verifyEmpty(testCase.Manager.active);
        end

        function resultListsClassifyAcceptedRuns(testCase)
            %RESULTLISTSCLASSIFYACCEPTEDRUNS Success needs completion and DONE.

            first = testCase.addAccepted();
            second = testCase.addAccepted();
            third = testCase.addAccepted();
            testCase.Queue.queue([ ...
                status(1, "DONE"), completed(1), ...
                status(2, "ERROR"), completed(2), ...
                completed(3)]);

            testCase.Manager.wait();

            testCase.verifyEqual(testCase.Manager.simulations, ...
                [first, second, third]);
            testCase.verifyEqual(testCase.Manager.succeeded, first);
            testCase.verifyEqual(testCase.Manager.failed, [second, third]);
        end


        % -----------------------------------------------------------------
        % shutdown
        % -----------------------------------------------------------------

        function shutdownDrainsPendingNonblockingSubmissions(testCase)
            testCase.makeManager();
            simulation = testCase.Manager.add(testCase.Deck, testCase.Config, ...
                blocking=false);
            testCase.Queue.queue([accepted(1), status(1, "DONE"), completed(1)]);
            mark = numel(testCase.Queue.calls);

            testCase.Manager.shutdown();

            testCase.verifyEqual(testCase.Queue.callsSince(mark), ...
                ["close", "readLine", "readLine", "readLine", "readLine", "wait"]);
            testCase.verifyTrue(simulation.succeeded);
            testCase.verifyEmpty(testCase.Manager.active);
            testCase.verifyEqual(testCase.Manager.submitted, simulation);
        end

        function shutdownClosesDrainsThenReaps(testCase)
            %SHUTDOWNCLOSESDRAINSTHENREAPS The order of transport calls is fixed.

            simulation = testCase.addAccepted();
            testCase.Queue.queue([status(1, "DONE"), completed(1)]);
            mark = numel(testCase.Queue.calls);

            testCase.Manager.shutdown();

            testCase.verifyEqual(testCase.Queue.callsSince(mark), ...
                ["close", "readLine", "readLine", "readLine", "wait"]);
            testCase.verifyTrue(simulation.succeeded);
        end

        function shutdownIsIdempotentAfterSuccess(testCase)
            %SHUTDOWNISIDEMPOTENTAFTERSUCCESS A completed shutdown does no further work.

            testCase.makeManager();
            testCase.Manager.shutdown();
            testCase.verifyEmpty(testCase.Manager.sessionDiagnostics, ...
                'Idle EOF during shutdown must be treated as normal.');
            mark = numel(testCase.Queue.calls);

            testCase.Manager.shutdown();

            testCase.verifyEmpty(testCase.Queue.callsSince(mark));
        end

        function pollIsRejectedAfterShutdown(testCase)
            testCase.makeManager();
            testCase.Manager.shutdown();
            mark = numel(testCase.Queue.calls);

            testCase.verifyError(@() testCase.Manager.poll(), ...
                'trnrun:ManagerShutdown');
            testCase.verifyEmpty(testCase.Queue.callsSince(mark));
        end

        function operationsAreRejectedAfterShutdownStarts(testCase)
            %OPERATIONSAREREJECTEDAFTERSHUTDOWNSTARTS Submission ends with shutdown.

            testCase.makeManager();
            testCase.Manager.shutdown();

            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config), 'trnrun:ManagerShutdown');
            testCase.verifyError(@() testCase.Manager.add( ...
                testCase.Deck, testCase.Config, blocking=false), ...
                'trnrun:ManagerShutdown');
        end

        function shutdownReportsANonZeroQueueExit(testCase)
            %SHUTDOWNREPORTSANONZEROQUEUEEXIT A failed queue process is surfaced.

            testCase.makeManager();
            testCase.Queue.exitCode = 7;
            testCase.Queue.stderr = "fatal: bad option";

            try
                testCase.Manager.shutdown();
                testCase.verifyFail('Expected a queue exit failure.');
            catch exception
                testCase.verifyEqual(exception.identifier, 'trnrun:QueueExitFailure');
                testCase.verifySubstring(exception.message, 'exited with code 7');
                testCase.verifySubstring(exception.message, ...
                    'Queue stderr: fatal: bad option');
            end
        end

        function shutdownReapsEvenWhenDrainingFails(testCase)
            %SHUTDOWNREAPSEVENWHENDRAININGFAILS The drain error wins over the exit code.

            testCase.addAccepted();
            testCase.Queue.exitCode = 13;
            mark = numel(testCase.Queue.calls);

            testCase.verifyError(@() testCase.Manager.shutdown(), ...
                'trnrun:PrematureQueueEOF');

            testCase.verifyTrue(ismember("wait", testCase.Queue.callsSince(mark)), ...
                'The queue must still be reaped.');
        end

        function anIncompleteShutdownCanBeRetried(testCase)
            %ANINCOMPLETESHUTDOWNCANBERETRIED A failed shutdown is not recorded as done.

            testCase.makeManager();
            testCase.Queue.exitCode = 7;
            testCase.verifyError(@() testCase.Manager.shutdown(), ...
                'trnrun:QueueExitFailure');
            mark = numel(testCase.Queue.calls);

            testCase.verifyError(@() testCase.Manager.shutdown(), ...
                'trnrun:QueueExitFailure');
            testCase.verifyNotEmpty(testCase.Queue.callsSince(mark));
        end


        % -----------------------------------------------------------------
        % Display
        % -----------------------------------------------------------------

        function aDisabledDisplayOpensNoWindow(testCase)
            %ADISABLEDDISPLAYOPENSNOWINDOW refreshInterval=0 keeps the session headless.

            before = findall(groot, 'Type', 'figure');
            testCase.makeManager();
            testCase.Queue.queue([accepted(1), status(1, "DONE"), completed(1)]);

            simulation = testCase.Manager.add(testCase.Deck, testCase.Config);
            testCase.Manager.wait(simulation);

            testCase.verifyEqual(findall(groot, 'Type', 'figure'), before);
        end

        function anEnabledDisplayShowsAcceptedRuns(testCase)
            %ANENABLEDDISPLAYSHOWSACCEPTEDRUNS Acceptance and completion reach the display.

            before = findall(groot, 'Type', 'figure');
            testCase.addTeardown(@() closeNewFigures(before));
            testCase.makeManager(refreshInterval=3600);
            testCase.Queue.queue([accepted(1), status(1, "DONE"), completed(1)]);

            simulation = testCase.Manager.add(testCase.Deck, testCase.Config); %#ok<NASGU>
            window = setdiff(findall(groot, 'Type', 'figure'), before);
            testCase.assertNumElements(window, 1);
            area = findall(window, 'Type', 'uitextarea');
            testCase.verifySubstring(area.Value{1}, 'model.dck');

            output = evalc('testCase.Manager.wait(simulation);');
            testCase.verifySubstring(output, 'Status: DONE');
        end
    end

    methods (Access = private)
        function makeManager(testCase, options)
            %MAKEMANAGER Create a headless manager backed by the scripted transport.

            arguments
                testCase
                options.maxConcurrent = 2
                options.refreshInterval = 0
                options.trnrunqPath = string.empty
            end

            args = {'maxConcurrent', options.maxConcurrent, ...
                'refreshInterval', options.refreshInterval};
            if ~isempty(options.trnrunqPath)
                args = [args, {'trnrunqPath', options.trnrunqPath}];
            end
            testCase.Manager = trnrun.SimulationManager(args{:});
            testCase.Queue = getappdata(0, 'TRNRunMockQueueProcess');
            testCase.assertNotEmpty(testCase.Queue, ...
                'The manager did not create a scripted transport.');
        end

        function simulation = addAccepted(testCase)
            %ADDACCEPTED Submit one run and script its acceptance.

            if isempty(testCase.Manager)
                testCase.makeManager();
            end
            nextId = numel(testCase.Manager.simulations) + 1;
            testCase.Queue.queue(accepted(nextId));
            simulation = testCase.Manager.add(testCase.Deck, testCase.Config);
        end
    end
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the toolbox folder next to this tests folder.

    folder = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox');
end

function folder = mockQueueFolder()
    %MOCKQUEUEFOLDER Return the folder holding the scripted transport.

    folder = fullfile(fileparts(mfilename('fullpath')), 'testdoubles');
end

function line = accepted(runId)
    %ACCEPTED Encode one QUEUE/ACCEPTED line.

    line = queueEvent(runId, "ACCEPTED");
end

function line = completed(runId)
    %COMPLETED Encode one QUEUE/COMPLETED line.

    line = queueEvent(runId, "COMPLETED");
end

function line = queueEvent(runId, event)
    %QUEUEEVENT Encode one QUEUE line with an arbitrary event name.

    line = string(sprintf( ...
        '{"runID":"%d","kind":"QUEUE","event":"%s","timestamp":"t","exitCode":0}', ...
        runId, event));
end

function line = status(runId, value, message)
    %STATUS Encode one STATUS line, optionally with a message.

    if nargin < 3
        message = "";
    end
    line = string(sprintf( ...
        ['{"runID":"%d","kind":"STATUS","status":"%s","timestamp":"t",' ...
         '"message":"%s"}'], runId, value, message));
end

function line = progress(runId, percent)
    %PROGRESS Encode one PROGRESS line.

    line = string(sprintf( ...
        ['{"runID":"%d","kind":"PROGRESS","time":1,"percent":%g,' ...
         '"elapsed":1000,"eta":1000,"timestamp":"t"}'], runId, percent));
end

function closeNewFigures(before)
    %CLOSENEWFIGURES Delete figures created since BEFORE was captured.

    created = setdiff(findall(groot, 'Type', 'figure'), before);
    delete(created(isgraphics(created)));
end
