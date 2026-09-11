classdef TestEventParsing < matlab.unittest.TestCase
    methods (Test)
        function parsesEveryNormalizedEventKind(testCase)
            contract = load_contract('events_contract.json');
            for index = 1:numel(contract.valid)
                test = item_at(contract.valid, index);
                [~, actual] = trnrun.internal.parseStreamLine(jsonencode(test.wire), "event");
                actual = rmfield(actual, 'kind');
                testCase.verifyEqual(actual, test.normalized, ...
                    sprintf('fixture case %s', test.name));
            end
        end

        function rejectsMalformedSingleEvents(testCase)
            contract = load_contract('events_contract.json');
            for index = 1:numel(contract.parseErrors)
                test = item_at(contract.parseErrors, index);
                try
                    trnrun.internal.parseStreamLine(test.line, "event");
                    testCase.assertFail(sprintf('Expected parse failure for %s.', test.name));
                catch exception
                    testCase.verifyEqual(exception.identifier, 'trnrun:EventParseError');
                    testCase.verifyTrue(contains(exception.message, test.messageContains), ...
                        sprintf('fixture case %s', test.name));
                end
            end
        end

        function ignoresUnroutableStreamDiagnostics(testCase)
            contract = load_contract('events_contract.json');
            for index = 1:numel(contract.unroutableStreamLines)
                line = item_at(contract.unroutableStreamLines, index);
                [run_id, event] = trnrun.internal.parseStreamLine(line);
                testCase.verifyEmpty(run_id);
                testCase.verifyEmpty(event);
            end
        end

        function routableMalformedEventsRaise(testCase)
            contract = load_contract('events_contract.json');
            for index = 1:numel(contract.routableStreamErrors)
                test = item_at(contract.routableStreamErrors, index);
                try
                    trnrun.internal.parseStreamLine(test.line);
                    testCase.assertFail(sprintf('Expected stream failure for %s.', test.name));
                catch exception
                    testCase.verifyEqual(exception.identifier, 'trnrun:EventParseError');
                    testCase.verifyTrue(contains(exception.message, test.messageContains));
                end
            end
        end

        function preservesStreamRunID(testCase)
            line = ['{"runID":"alpha","kind":"PROGRESS","time":1,' ...
                '"percent":0.25,"elapsed":20,"eta":60,"timestamp":"t"}'];
            [run_id, event] = trnrun.internal.parseStreamLine(line);
            testCase.verifyEqual(run_id, 'alpha');
            testCase.verifyEqual(event.percent, 0.25);
        end

        function acceptsIntegralJsonDoublesForIntegerFields(testCase)
            data = struct('kind', 'QUEUE', 'event', 'COMPLETED', ...
                'runID', '1', 'timestamp', 't', 'exitCode', 2.0);
            [~, event] = trnrun.internal.parseStreamLine(jsonencode(data), "event");
            testCase.verifyEqual(event.exit_code, 2);
        end
    end
end

function contract = load_contract(name)
path = fullfile(testsupport.fixtureRoot(), name);
contract = jsondecode(fileread(path));
end

function value = item_at(collection, index)
if iscell(collection)
    value = collection{index};
else
    value = collection(index);
end
end
