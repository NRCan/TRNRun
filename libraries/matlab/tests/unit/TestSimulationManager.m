classdef TestSimulationManager < matlab.unittest.TestCase
    methods (Test)
        function runsOneSimulationToSuccess(testCase)
            files = testsupport.TemporaryFiles();
            transport = testsupport.ScriptedQueueProcess({ ...
                queue_line('ACCEPTED', '1', []), ...
                status_line('1', 'DONE'), ...
                queue_line('COMPLETED', '1', 0), ...
                []});
            manager = make_manager(transport);
            cleanup = onCleanup(@() cleanup_all(manager, files)); %#ok<NASGU>

            config = files.config();
            simulation = manager.add(files.deck, config);
            config.watch_tmp = true;
            manager.wait();
            manager.shutdown();
            manager.shutdown();

            testCase.verifyTrue(simulation.succeeded);
            testCase.verifyFalse(simulation.config.watch_tmp);
            testCase.verifyEqual(numel(manager.simulations), 1);
            testCase.verifyEqual(numel(manager.succeeded), 1);
            testCase.verifyEmpty(manager.failed);
            testCase.verifyTrue(transport.closed);
            testCase.verifyTrue(transport.waited);
            testCase.verifyEqual(transport.sent{1}.runID, '1');
            testCase.verifyEqual(transport.sent{1}.deckFile, files.deck);
            testCase.verifyEqual(transport.sent{1}.runnerPath, files.runner);
            testCase.verifyEqual(numel(transport.sent{1}.runnerArgs), 17);
            testCase.verifyError(@() manager.add(files.deck, files.config()), ...
                'trnrun:ManagerShutdown');
        end

        function waitingForOneStillUpdatesOthers(testCase)
            files = testsupport.TemporaryFiles();
            progress = struct('kind', 'PROGRESS', 'runID', '2', ...
                'time', 5, 'percent', 0.5, 'elapsed', 10, 'eta', 10, ...
                'timestamp', 'p');
            transport = testsupport.ScriptedQueueProcess({ ...
                queue_line('ACCEPTED', '1', []), ...
                status_line('1', 'RUNNING'), ...
                queue_line('ACCEPTED', '2', []), ...
                jsonencode(progress), ...
                status_line('1', 'DONE'), ...
                queue_line('COMPLETED', '1', 0), ...
                status_line('2', 'DONE'), ...
                queue_line('COMPLETED', '2', 0), ...
                []});
            manager = make_manager(transport);
            cleanup = onCleanup(@() cleanup_all(manager, files)); %#ok<NASGU>

            first = manager.add(files.deck, files.config());
            second = manager.add(files.deck, files.config());
            manager.wait(first);
            testCase.verifyTrue(first.isFinished);
            testCase.verifyFalse(second.isFinished);
            testCase.verifyEqual(second.progress.percent, 0.5);
            manager.wait();
            manager.shutdown();
            testCase.verifyTrue(second.succeeded);
        end

        function followInvokesOnlyNewAppliedUpdates(testCase)
            files = testsupport.TemporaryFiles();
            transport = testsupport.ScriptedQueueProcess({ ...
                queue_line('ACCEPTED', '1', []), ...
                status_line('1', 'RUNNING'), ...
                status_line('1', 'DONE'), ...
                queue_line('COMPLETED', '1', 0), ...
                []});
            manager = make_manager(transport);
            cleanup = onCleanup(@() cleanup_all(manager, files)); %#ok<NASGU>
            manager.add(files.deck, files.config());
            recorder = testsupport.CallbackRecorder();
            manager.follow(@(simulation) recorder.invoke(simulation));
            manager.shutdown();

            testCase.verifyEqual(recorder.count, 3);
            testCase.verifyTrue(recorder.last.isFinished);
        end

        function rejectsCallbackReentrancyButRemainsDrainable(testCase)
            files = testsupport.TemporaryFiles();
            transport = testsupport.ScriptedQueueProcess({ ...
                queue_line('ACCEPTED', '1', []), ...
                status_line('1', 'RUNNING'), ...
                status_line('1', 'DONE'), ...
                queue_line('COMPLETED', '1', 0), ...
                []});
            manager = make_manager(transport);
            cleanup = onCleanup(@() cleanup_all(manager, files)); %#ok<NASGU>
            manager.add(files.deck, files.config());
            recorder = testsupport.CallbackRecorder();
            recorder.manager = manager;
            recorder.mode = 'reenter';

            testCase.verifyError(@() manager.follow( ...
                @(simulation) recorder.invoke(simulation)), ...
                'trnrun:ReentrantOperation');
            manager.shutdown();
        end

        function callbackFailurePropagatesAndDeleteForcesCleanup(testCase)
            files = testsupport.TemporaryFiles();
            transport = testsupport.ScriptedQueueProcess({ ...
                queue_line('ACCEPTED', '1', []), ...
                status_line('1', 'RUNNING')});
            manager = make_manager(transport);
            manager.add(files.deck, files.config());
            recorder = testsupport.CallbackRecorder();
            recorder.mode = 'error';
            testCase.verifyError(@() manager.follow( ...
                @(simulation) recorder.invoke(simulation)), ...
                'testsupport:CallbackFailure');
            delete(manager);
            delete(files);
            testCase.verifyTrue(transport.forced);
        end

        function reportsPrematureEofWithoutInventingCompletion(testCase)
            files = testsupport.TemporaryFiles();
            transport = testsupport.ScriptedQueueProcess({ ...
                queue_line('ACCEPTED', '1', []), []});
            manager = make_manager(transport);
            cleanup = onCleanup(@() cleanup_all(manager, files)); %#ok<NASGU>
            simulation = manager.add(files.deck, files.config());
            testCase.verifyError(@() manager.wait(), 'trnrun:PrematureQueueEOF');
            testCase.verifyFalse(simulation.isFinished);
            testCase.verifyEmpty(simulation.completionEvent);
        end

        function rejectsForeignSimulation(testCase)
            files = testsupport.TemporaryFiles();
            transport = testsupport.ScriptedQueueProcess();
            manager = make_manager(transport);
            cleanup = onCleanup(@() cleanup_all(manager, files)); %#ok<NASGU>
            foreign = trnrun.Simulation(files.deck, files.config(), 99);
            testCase.verifyError(@() manager.wait(foreign), ...
                'trnrun:ForeignSimulation');
        end

        function nonzeroQueueExitRaisesEvenWithoutActiveRuns(testCase)
            files = testsupport.TemporaryFiles();
            transport = testsupport.ScriptedQueueProcess({ ...
                queue_line('ACCEPTED', '1', []), ...
                status_line('1', 'DONE'), ...
                queue_line('COMPLETED', '1', 0), []}, 2);
            manager = make_manager(transport);
            cleanup = onCleanup(@() cleanup_all(manager, files)); %#ok<NASGU>
            manager.add(files.deck, files.config());
            manager.wait();
            testCase.verifyError(@() manager.shutdown(), ...
                'trnrun:QueueExitFailure');
        end

        function malformedAndUnknownLinesAreBoundedDiagnostics(testCase)
            files = testsupport.TemporaryFiles();
            lines = {'native output'};
            for index = 1:205
                lines{end + 1} = sprintf('{"runID":"missing-%d","kind":"STATUS"}', index); %#ok<AGROW>
            end
            lines = [lines, {queue_line('ACCEPTED', '1', []), ...
                status_line('1', 'DONE'), queue_line('COMPLETED', '1', 0), []}];
            transport = testsupport.ScriptedQueueProcess(lines);
            manager = make_manager(transport);
            cleanup = onCleanup(@() cleanup_all(manager, files)); %#ok<NASGU>
            manager.add(files.deck, files.config());
            manager.wait();
            manager.shutdown();
            testCase.verifyEqual(numel(manager.session_diagnostics), 200);
        end
    end
end

function manager = make_manager(transport)
manager = trnrun.SimulationManager( ...
    'max_concurrent', 2, ...
    'refresh_interval', 0, ...
    'transport', transport);
end

function line = queue_line(event, run_id, exit_code)
if strcmp(event, 'COMPLETED') && isempty(exit_code)
    line = sprintf(['{"kind":"QUEUE","event":"COMPLETED",' ...
        '"runID":"%s","timestamp":"t","exitCode":null}'], run_id);
else
    data = struct('kind', 'QUEUE', 'event', event, ...
        'runID', run_id, 'timestamp', 't');
    if strcmp(event, 'COMPLETED')
        data.exitCode = exit_code;
    end
    line = jsonencode(data);
end
end

function line = status_line(run_id, status)
data = struct('kind', 'STATUS', 'runID', run_id, ...
    'status', status, 'timestamp', 't', 'message', '');
line = jsonencode(data);
end

function cleanup_all(manager, files)
try
    delete(manager);
catch
end
try
    delete(files);
catch
end
end
