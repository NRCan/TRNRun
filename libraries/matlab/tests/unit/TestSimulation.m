classdef TestSimulation < matlab.unittest.TestCase
    methods (Test)
        function eventsAreStoredWithPrivateWriteAccess(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            names = {'status', 'progress', 'configEvent', ...
                'settingEvent', 'completionEvent'};
            kinds = {'STATUS', 'PROGRESS', 'CONFIG', 'SETTING'};
            observer = simulation;
            for index = 1:numel(names)
                property = findprop(simulation, names{index});
                testCase.verifyFalse(property.Dependent);
                testCase.verifyEqual(property.GetAccess, 'public');
                testCase.verifyEqual(property.SetAccess, 'private');
                testCase.verifyEmpty(simulation.(names{index}));
                if index <= numel(kinds)
                    event = struct('kind', kinds{index}, 'timestamp', 't');
                    simulation.applyEvent(event);
                else
                    event = completionEvent(0);
                    simulation.markCompleted(event);
                end
                testCase.verifyEqual(observer.(names{index}), event);
                snapshot = observer.(names{index});
                snapshot.timestamp = 'changed';
                testCase.verifyEqual(simulation.(names{index}), event);
            end
        end

        function acceptanceAndCountersAreStoredWithPrivateWriteAccess(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            names = {'isAccepted', 'logCount', 'notices', 'warnings', 'fatals'};
            initial = {false, 0, 0, 0, 0};
            for index = 1:numel(names)
                property = findprop(simulation, names{index});
                testCase.verifyFalse(property.Dependent);
                testCase.verifyEqual(property.GetAccess, 'public');
                testCase.verifyEqual(property.SetAccess, 'private');
                testCase.verifyEqual(simulation.(names{index}), initial{index});
            end

            observer = simulation;
            simulation.markAccepted();
            severities = {'Notice', 'Warning', 'Fatal', 'Unknown'};
            for index = 1:numel(severities)
                simulation.applyEvent(struct('kind', 'LOG', 'severity', severities{index}));
            end
            testCase.verifyTrue(observer.isAccepted);
            testCase.verifyEqual(observer.logCount, 4);
            testCase.verifyEqual([observer.notices, observer.warnings, observer.fatals], [1, 1, 1]);
            testCase.verifyEqual(numel(observer.logs), 4);
        end

        function logsAreStoredWithPrivateWriteAccess(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            testCase.verifyEmpty(simulation.logs);
            logs = findprop(simulation, 'logs');
            testCase.verifyFalse(logs.Dependent);
            testCase.verifyEqual(logs.GetAccess, 'public');
            testCase.verifyEqual(logs.SetAccess, 'private');
        end

        function stateTracksAcceptanceAndCompletionNotStatus(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            testCase.verifyEqual(simulation.state, 'pending');
            testCase.verifyClass(simulation.state, 'char');
            testCase.verifyTrue(simulation.isRunning);
            simulation.applyEvent(status_event('RUNNING'));
            testCase.verifyEqual(simulation.state, 'pending');
            simulation.markAccepted();
            testCase.verifyEqual(simulation.state, 'running');
            testCase.verifyClass(simulation.state, 'char');
            simulation.applyEvent(status_event('DONE'));
            testCase.verifyEqual(simulation.state, 'running');
            testCase.verifyTrue(simulation.isRunning);
            simulation.markCompleted(completionEvent(0));
            testCase.verifyEqual(simulation.state, 'finished');
            testCase.verifyClass(simulation.state, 'char');
            testCase.verifyFalse(simulation.isRunning);
        end

        function completionWithoutAcceptanceFinishes(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            simulation.markCompleted(completionEvent([]));
            testCase.verifyFalse(simulation.isAccepted);
            testCase.verifyEqual(simulation.state, 'finished');
            testCase.verifyFalse(simulation.isRunning);
            simulation.markAccepted();
            testCase.verifyEqual(simulation.state, 'finished');
        end

        function statusTablePreservesValuesAndArrayOrder(testCase)
            files = testsupport.TemporaryFiles();
            cleanup = onCleanup(@() delete(files)); %#ok<NASGU>
            pending = trnrun.Simulation(files.deck, files.config(), 9);
            running = trnrun.Simulation(files.deck, files.config(), 2);
            finished = trnrun.Simulation(files.deck, files.config(), 7);
            running.markAccepted();
            running.applyEvent(status_event('RUNNING'));
            running.applyEvent(struct('kind', 'PROGRESS', 'percent', 0.375));
            finished.applyEvent(status_event('ERROR'));
            finished.applyEvent(struct('kind', 'PROGRESS', 'percent', 0.8));
            finished.applyEvent(log_event(1, 'Notice'));
            finished.applyEvent(log_event(2, 'Warning'));
            finished.applyEvent(log_event(3, 'Warning'));
            finished.applyEvent(log_event(4, 'Fatal'));
            finished.markCompleted(completionEvent(12));

            row = [pending, running, finished];
            actual = statusTable(row);
            verify_status_schema(testCase, actual, 3);
            testCase.verifyEqual(actual.id, [9; 2; 7]);
            testCase.verifyEqual(actual.deckPath, repmat(string(pending.deckPath), 3, 1));
            testCase.verifyEqual(actual.state, ["pending"; "running"; "finished"]);
            testCase.verifyTrue(ismissing(actual.status(1)));
            testCase.verifyEqual(actual.status(2:3), ["RUNNING"; "ERROR"]);
            testCase.verifyEqual(actual.percent, [NaN; 0.375; 0.8]);
            testCase.verifyEqual(actual.exitCode, [NaN; NaN; 12]);
            testCase.verifyEqual(actual.notices, [0; 0; 1]);
            testCase.verifyEqual(actual.warnings, [0; 0; 2]);
            testCase.verifyEqual(actual.fatals, [0; 0; 1]);
            testCase.verifyEqual(statusTable(reshape(row, [], 1)), actual);
            testCase.verifyEqual(statusTable(finished), actual(3, :));
        end

        function statusTableNormalizesAbsentAndEmptyFields(testCase)
            for variant = 1:3
                [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
                completion = completionEvent([]);
                if variant == 1
                    completion = rmfield(completion, 'exitCode');
                elseif variant == 2
                    simulation.applyEvent(struct('kind', 'STATUS'));
                    simulation.applyEvent(struct('kind', 'PROGRESS'));
                else
                    simulation.applyEvent(status_event([]));
                    simulation.applyEvent(struct('kind', 'PROGRESS', 'percent', []));
                end
                simulation.markCompleted(completion);
                actual = statusTable(simulation);
                verify_status_schema(testCase, actual, 1);
                testCase.verifyTrue(ismissing(actual.status));
                testCase.verifyTrue(isnan(actual.percent));
                testCase.verifyTrue(isnan(actual.exitCode));
                clear cleanup
            end
        end

        function parsedCompletionPreservesExitCodeWithoutSynthesizingDone(testCase)
            fields = {',"exitCode":0', ',"exitCode":12', ...
                ',"exitCode":null', ''};
            expected = [0, 12, NaN, NaN];
            for index = 1:numel(fields)
                [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
                line = ['{"kind":"QUEUE","event":"COMPLETED",' ...
                    '"runID":"1","timestamp":"t"' fields{index} '}'];
                [runID, event] = trnrun.internal.parseStreamLine(line);
                testCase.verifyEqual(runID, '1');
                testCase.assertEqual(event.exitCode, expected(index));
                simulation.markCompleted(event);

                actual = statusTable(simulation);
                verify_status_schema(testCase, actual, 1);
                testCase.verifyEqual(actual.exitCode, expected(index));
                testCase.verifyEqual(simulation.completionEvent, event);
                testCase.verifyTrue(simulation.isFinished);
                testCase.verifyFalse(simulation.isRunning);
                testCase.verifyEmpty(simulation.status);
                testCase.verifyTrue(ismissing(actual.status));
                testCase.verifyFalse(simulation.hasTerminalStatus);
                testCase.verifyFalse(simulation.succeeded);
                clear cleanup
            end
        end

        function parsedDoneAndCompletionSucceed(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            [runID, status] = trnrun.internal.parseStreamLine( ...
                '{"kind":"STATUS","status":"DONE","runID":"1","timestamp":"s"}');
            testCase.verifyEqual(runID, '1');
            simulation.applyEvent(status);
            testCase.verifyTrue(simulation.hasTerminalStatus);
            testCase.verifyFalse(simulation.isFinished);
            testCase.verifyFalse(simulation.succeeded);

            [runID, completion] = trnrun.internal.parseStreamLine( ...
                ['{"kind":"QUEUE","event":"COMPLETED","runID":"1",' ...
                '"timestamp":"t","exitCode":0}']);
            testCase.verifyEqual(runID, '1');
            simulation.markCompleted(completion);
            testCase.verifyEqual(simulation.status, status);
            testCase.verifyEqual(simulation.completionEvent, completion);
            testCase.verifyTrue(simulation.isFinished);
            testCase.verifyTrue(simulation.succeeded);
            actual = statusTable(simulation);
            verify_status_schema(testCase, actual, 1);
            testCase.verifyEqual(actual.status, "DONE");
            testCase.verifyEqual(actual.exitCode, 0);
        end

        function emptyStatusTablesKeepColumnSchema(testCase)
            shapes = {[0, 0], [1, 0], [0, 1]};
            for index = 1:numel(shapes)
                shape = shapes{index};
                simulations = trnrun.Simulation.empty(shape(1), shape(2));
                actual = statusTable(simulations);
                verify_status_schema(testCase, actual, 0);
            end
        end

        function logTableMatchesAllLogsInOrder(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            testCase.verifyEqual(simulation.logTable(), table());
            severities = {'Notice', 'WARNING', 'fatal', 'Unknown'};
            for code = 1:12
                simulation.applyEvent(log_event(code, severities{mod(code - 1, 4) + 1}));
                logs = simulation.logs;
                testCase.verifyEqual([logs.messageCode], 1:code);
                testCase.verifyEqual(simulation.logTable(), ...
                    struct2table(logs, 'AsArray', true));
            end
            testCase.verifyEqual(simulation.logCount, 12);
            testCase.verifyEqual(simulation.notices, 3);
            testCase.verifyEqual(simulation.warnings, 3);
            testCase.verifyEqual(simulation.fatals, 3);
        end

        function unknownSeverityIsRetainedAndCounted(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            event = log_event(1, 'Unknown');
            simulation.applyEvent(event);
            testCase.verifyEqual(simulation.logs, event);
            testCase.verifyEqual(simulation.logTable(), struct2table(event, 'AsArray', true));
            testCase.verifyEqual(simulation.logCount, 1);
            testCase.verifyEqual([simulation.notices, simulation.warnings, simulation.fatals], [0, 0, 0]);
        end

        function rejectsInvalidConstructorArguments(testCase)
            files = testsupport.TemporaryFiles();
            cleanup = onCleanup(@() delete(files)); %#ok<NASGU>
            config = files.config();
            invalidConfigs = {[], struct(), {config}, [config, config]};
            for index = 1:numel(invalidConfigs)
                testCase.verifyError(@() trnrun.Simulation(files.deck, invalidConfigs{index}, 1), ...
                    'trnrun:InvalidConfig');
            end
            invalidIntegers = {[], [1, 2], '1', true, NaN, Inf, 1i, 1.5, -1};
            for index = 1:numel(invalidIntegers)
                value = invalidIntegers{index};
                testCase.verifyError(@() trnrun.Simulation(files.deck, config, value), ...
                    'trnrun:InvalidInteger');

            end
            testCase.verifyError(@() trnrun.Simulation(files.deck, config, 0), ...
                'trnrun:InvalidInteger');
        end

        function invalidCompletionDoesNotMutateSimulation(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            valid = completionEvent(0);
            invalid = {[], 'COMPLETED', [valid, valid], ...
                rmfield(valid, 'kind'), rmfield(valid, 'event'), ...
                status_event('DONE'), struct('kind', 'STATUS', 'event', 'COMPLETED'), ...
                struct('kind', 'QUEUE', 'event', 'ACCEPTED')};
            for index = 1:numel(invalid)
                testCase.verifyError(@() simulation.markCompleted(invalid{index}), ...
                    'trnrun:InvalidCompletionEvent');
                testCase.verifyEmpty(simulation.completionEvent);
                testCase.verifyFalse(simulation.isFinished);
            end
        end

        function duplicateCompletionPreservesFirstEvent(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            first = completionEvent([]);
            simulation.markCompleted(first);
            simulation.markCompleted(completionEvent(42));
            testCase.verifyEqual(simulation.completionEvent, first);
            testCase.verifyTrue(simulation.isFinished);
        end

        function terminalStatusDoesNotFinish(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            simulation.markAccepted();
            simulation.applyEvent(status_event('DONE'));
            testCase.verifyTrue(simulation.isAccepted);
            testCase.verifyTrue(simulation.hasTerminalStatus);
            testCase.verifyFalse(simulation.isFinished);
            testCase.verifyFalse(simulation.succeeded);
        end

        function completionAndDoneAreBothRequiredForSuccess(testCase)
            statuses = {'DONE', 'ERROR', 'CANCELLED', 'TIMEOUT', 'STALLED'};
            for index = 1:numel(statuses)
                [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
                simulation.applyEvent(status_event(statuses{index}));
                simulation.markCompleted(completionEvent(0));
                testCase.verifyTrue(simulation.isFinished);
                testCase.verifyEqual(simulation.succeeded, strcmp(statuses{index}, 'DONE'));
                clear cleanup
            end

            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            simulation.markCompleted(completionEvent(0));
            testCase.verifyFalse(simulation.succeeded);
            testCase.verifyEmpty(simulation.status);
        end

        function preservesNullExitCodeAndIgnoresLaterEvents(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            completion = completionEvent([]);
            simulation.markCompleted(completion);
            simulation.applyEvent(status_event('DONE'));
            testCase.verifyEmpty(simulation.completionEvent.exitCode);
            testCase.verifyEmpty(simulation.status);
            testCase.verifyFalse(simulation.succeeded);
        end

        function retainsLatestEventOfEachKind(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            simulation.applyEvent(status_event('PENDING'));
            simulation.applyEvent(status_event('RUNNING'));
            simulation.applyEvent(struct('kind', 'CONFIG', 'start', 0, ...
                'stop', 8760, 'step', 1, 'timestamp', 'c'));
            simulation.applyEvent(struct('kind', 'PROGRESS', 'time', 2, ...
                'percent', 0.5, 'elapsed', 10, 'eta', 10, 'timestamp', 'p'));
            testCase.verifyEqual(simulation.status.status, 'RUNNING');
            testCase.verifyEqual(simulation.configEvent.stop, 8760);
            testCase.verifyEqual(simulation.progress.percent, 0.5);
        end

        function logsBeyondFormerLimitAreRetainedWithCounters(testCase)
            [simulation, cleanup] = make_simulation(); %#ok<ASGLU>
            severities = {'Notice', 'Warning', 'Fatal'};
            for code = 0:5002
                event = struct( ...
                    'kind', 'LOG', ...
                    'runID', '1', ...
                    'severity', severities{mod(code, 3) + 1}, ...
                    'timestamp', 't', ...
                    'time', [], ...
                    'unitID', [], ...
                    'typeID', [], ...
                    'messageCode', code, ...
                    'message', sprintf('log-%04d', code), ...
                    'information', []);
                simulation.applyEvent(event);
            end

            logs = simulation.logs;
            testCase.verifyEqual(numel(logs), 5003);
            testCase.verifyEqual([logs.messageCode], 0:5002);
            testCase.verifyEqual(logs(end).messageCode, 5002);
            testCase.verifyEqual(simulation.logCount, 5003);
            testCase.verifyEqual(simulation.notices, 1668);
            testCase.verifyEqual(simulation.warnings, 1668);
            testCase.verifyEqual(simulation.fatals, 1667);

            logs(1).message = 'changed';
            fresh = simulation.logs;
            testCase.verifyNotEqual(fresh(1).message, 'changed');
        end


    end
end

function [simulation, cleanup] = make_simulation()
files = testsupport.TemporaryFiles();
cleanup = onCleanup(@() delete(files));
simulation = trnrun.Simulation(files.deck, files.config(), 1);
end

function verify_status_schema(testCase, actual, row_count)
testCase.verifyClass(actual, 'table');
testCase.verifyEqual(actual.Properties.VariableNames, ...
    {'id', 'deckPath', 'state', 'status', 'percent', 'exitCode', ...
    'notices', 'warnings', 'fatals'});
testCase.verifySize(actual, [row_count, 9]);
text_columns = {'deckPath', 'state', 'status'};
for index = 1:numel(text_columns)
    testCase.verifyClass(actual.(text_columns{index}), 'string');
    testCase.verifySize(actual.(text_columns{index}), [row_count, 1]);
end
numeric_columns = {'id', 'percent', 'exitCode', 'notices', 'warnings', 'fatals'};
for index = 1:numel(numeric_columns)
    testCase.verifyTrue(isnumeric(actual.(numeric_columns{index})));
    testCase.verifySize(actual.(numeric_columns{index}), [row_count, 1]);
end
end

function event = log_event(code, severity)
event = struct('kind', 'LOG', 'runID', '1', 'severity', severity, ...
    'timestamp', 't', 'time', [], 'unitID', [], 'typeID', [], ...
    'messageCode', code, 'message', sprintf('log-%04d', code), ...
    'information', []);
end

function event = status_event(status)
event = struct('kind', 'STATUS', 'status', status, ...
    'timestamp', 't', 'message', '');
end

function event = completionEvent(exitCode)
event = struct('kind', 'QUEUE', 'event', 'COMPLETED', ...
    'runID', '1', 'timestamp', 't', 'exitCode', exitCode);
end
