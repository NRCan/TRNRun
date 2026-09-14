classdef ParseStreamLineTest < matlab.unittest.TestCase
    %PARSESTREAMLINETEST Unit tests for trnrun.internal.parseStreamLine.
    %   Covers the three outcomes of the parser: ignored stdout, routable
    %   events, and malformed events that raise trnrun:EventParseError.

    properties (Constant)
        ParseError = 'trnrun:EventParseError'
    end

    methods (TestClassSetup)
        function addToolbox(testCase)
            %ADDTOOLBOX Put the toolbox on the path for the whole class.

            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                toolboxFolder()));
        end
    end

    methods (Test)
        % -----------------------------------------------------------------
        % Input rejection: never an event, never an error
        % -----------------------------------------------------------------

        function ignoresNonTextInput(testCase)
            %IGNORESNONTEXTINPUT Only char rows and string scalars can be lines.

            inputs = {42, {'{"a":1}'}, ["a" "b"], string(missing), ...
                ['ab'; 'cd'], '', struct('a', 1), true};
            for index = 1:numel(inputs)
                [runId, event] = trnrun.internal.parseStreamLine(inputs{index});
                testCase.verifyEmpty(runId, sprintf('input %d', index));
                testCase.verifyEmpty(event, sprintf('input %d', index));
            end
        end

        function ignoresInvalidJson(testCase)
            %IGNORESINVALIDJSON Plain diagnostics on stdout are not events.

            lines = {'starting queue', '{"unterminated": ', 'null', ...
                '{}{}', 'INFO: run 1 launched'};
            for index = 1:numel(lines)
                [runId, event] = trnrun.internal.parseStreamLine(lines{index});
                testCase.verifyEmpty(runId, lines{index});
                testCase.verifyEmpty(event, lines{index});
            end
        end

        function ignoresJsonWithoutRouting(testCase)
            %IGNORESJSONWITHOUTROUTING Valid JSON is only an event when routable.

            lines = { ...
                '[1,2,3]', ...
                '"a string"', ...
                '17', ...
                '{"kind":"STATUS"}', ...
                '{"runID":"1"}', ...
                '{"runID":1,"kind":"STATUS"}', ...
                '{"runID":"1","kind":7}', ...
                '{"runID":["1","2"],"kind":"STATUS"}', ...
                '{"runID":"1","kind":null}', ...
                '[{"runID":"1","kind":"STATUS"},{"runID":"2","kind":"STATUS"}]'};
            for index = 1:numel(lines)
                [runId, event] = trnrun.internal.parseStreamLine(lines{index});
                testCase.verifyEmpty(runId, lines{index});
                testCase.verifyEmpty(event, lines{index});
            end
        end

        function treatsASingleElementJsonArrayAsAnObject(testCase)
            %TREATSASINGLEELEMENTJSONARRAYASANOBJECT jsondecode collapses it to a scalar.
            %   The queue never frames events this way, so the resulting
            %   malformed event is reported rather than silently routed.

            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                '[{"runID":"1","kind":"STATUS"}]'), testCase.ParseError);
        end

        function acceptsStringScalarLine(testCase)
            %ACCEPTSSTRINGSCALARLINE String and char lines parse identically.

            line = '{"runID":"3","kind":"STATUS","status":"RUNNING","timestamp":"t"}';
            [charId, charEvent] = trnrun.internal.parseStreamLine(line);
            [stringId, stringEvent] = trnrun.internal.parseStreamLine(string(line));

            testCase.verifyEqual(stringId, charId);
            testCase.verifyEqual(stringEvent, charEvent);
        end

        function rejectsUnknownKind(testCase)
            %REJECTSUNKNOWNKIND A routable object with no parser is malformed.

            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                '{"runID":"1","kind":"HEARTBEAT"}'), testCase.ParseError);
        end

        % -----------------------------------------------------------------
        % STATUS
        % -----------------------------------------------------------------

        function parsesStatusWithMessage(testCase)
            %PARSESSTATUSWITHMESSAGE Every STATUS field is a string scalar.

            [runId, event] = trnrun.internal.parseStreamLine( ...
                ['{"runID":"12","kind":"STATUS","status":"RUNNING",' ...
                 '"timestamp":"t0","message":"launched"}']);

            testCase.verifyEqual(runId, '12');
            testCase.verifyEqual(event, struct( ...
                'kind', "STATUS", 'runID', "12", 'status', "RUNNING", ...
                'timestamp', "t0", 'message', "launched"));
        end

        function defaultsStatusMessageToEmptyString(testCase)
            %DEFAULTSSTATUSMESSAGETOEMPTYSTRING Only STATUS.message defaults to "".

            [~, absent] = trnrun.internal.parseStreamLine( ...
                '{"runID":"1","kind":"STATUS","status":"DONE","timestamp":"t"}');
            [~, null] = trnrun.internal.parseStreamLine( ...
                '{"runID":"1","kind":"STATUS","status":"DONE","timestamp":"t","message":null}');

            testCase.verifyEqual(absent.message, "");
            testCase.verifyEqual(null.message, "");
        end

        function acceptsEmptyTextFields(testCase)
            %ACCEPTSEMPTYTEXTFIELDS JSON "" decodes to '' and stays a string.

            [~, event] = trnrun.internal.parseStreamLine( ...
                '{"runID":"1","kind":"STATUS","status":"","timestamp":"t","message":""}');

            testCase.verifyEqual(event.status, "");
            testCase.verifyEqual(event.message, "");
        end

        function rejectsStatusWithMissingOrNonTextFields(testCase)
            %REJECTSSTATUSWITHMISSINGORNONTEXTFIELDS Required text must be text.

            lines = { ...
                '{"runID":"1","kind":"STATUS","timestamp":"t"}', ...
                '{"runID":"1","kind":"STATUS","status":"DONE"}', ...
                '{"runID":"1","kind":"STATUS","status":5,"timestamp":"t"}', ...
                '{"runID":"1","kind":"STATUS","status":true,"timestamp":"t"}', ...
                '{"runID":"1","kind":"STATUS","status":["a"],"timestamp":"t"}', ...
                '{"runID":"1","kind":"STATUS","status":"DONE","timestamp":"t","message":3}'};
            for index = 1:numel(lines)
                testCase.verifyError(@() trnrun.internal.parseStreamLine(lines{index}), ...
                    testCase.ParseError, lines{index});
            end
        end

        function normalizesKindCaseButNotValues(testCase)
            %NORMALIZESKINDCASEBUTNOTVALUES Dispatch ignores case; payloads do not.

            [~, event] = trnrun.internal.parseStreamLine( ...
                '{"runID":"1","kind":"status","status":"done","timestamp":"t"}');

            testCase.verifyEqual(event.kind, "STATUS");
            testCase.verifyEqual(event.status, "done");
        end

        % -----------------------------------------------------------------
        % PROGRESS and CONFIG
        % -----------------------------------------------------------------

        function parsesProgress(testCase)
            %PARSESPROGRESS Numeric PROGRESS fields become doubles.

            [runId, event] = trnrun.internal.parseStreamLine( ...
                ['{"runID":"2","kind":"PROGRESS","time":4380.5,"percent":0.5,' ...
                 '"elapsed":1000,"eta":2000,"timestamp":"t"}']);

            testCase.verifyEqual(runId, '2');
            testCase.verifyEqual(event, struct( ...
                'kind', "PROGRESS", 'runID', "2", 'time', 4380.5, ...
                'percent', 0.5, 'elapsed', 1000, 'eta', 2000, 'timestamp', "t"));
            testCase.verifyClass(event.time, 'double');
        end

        function rejectsProgressWithNonNumericFields(testCase)
            %REJECTSPROGRESSWITHNONNUMERICFIELDS Booleans, text and non-finite fail.

            template = ['{"runID":"2","kind":"PROGRESS","time":%s,"percent":0.5,' ...
                        '"elapsed":1,"eta":2,"timestamp":"t"}'];
            values = {'"5"', 'true', 'null', '[1,2]', '{"a":1}'};
            for index = 1:numel(values)
                line = sprintf(template, values{index});
                testCase.verifyError(@() trnrun.internal.parseStreamLine(line), ...
                    testCase.ParseError, line);
            end

            % jsondecode maps these to non-finite doubles rather than failing.
            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                ['{"runID":"2","kind":"PROGRESS","time":1e999,"percent":0.5,' ...
                 '"elapsed":1,"eta":2,"timestamp":"t"}']), testCase.ParseError);
        end

        function rejectsProgressMissingRequiredField(testCase)
            %REJECTSPROGRESSMISSINGREQUIREDFIELD PROGRESS has no optional fields.

            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                '{"runID":"2","kind":"PROGRESS","time":1,"percent":0.5,"eta":2,"timestamp":"t"}'), ...
                testCase.ParseError);
        end

        function parsesConfig(testCase)
            %PARSESCONFIG CONFIG carries the simulation time bounds.

            [runId, event] = trnrun.internal.parseStreamLine( ...
                ['{"runID":"9","kind":"CONFIG","start":0,"stop":8760,' ...
                 '"step":0.125,"timestamp":"t"}']);

            testCase.verifyEqual(runId, '9');
            testCase.verifyEqual(event, struct( ...
                'kind', "CONFIG", 'runID', "9", 'start', 0, 'stop', 8760, ...
                'step', 0.125, 'timestamp', "t"));
        end

        function rejectsConfigMissingBound(testCase)
            %REJECTSCONFIGMISSINGBOUND Every CONFIG bound is required.

            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                '{"runID":"9","kind":"CONFIG","start":0,"stop":8760,"timestamp":"t"}'), ...
                testCase.ParseError);
        end

        % -----------------------------------------------------------------
        % SETTING
        % -----------------------------------------------------------------

        function parsesSetting(testCase)
            %PARSESSETTING SETTING mirrors the runner CLI options.

            [runId, event] = trnrun.internal.parseStreamLine(settingLine());

            testCase.verifyEqual(runId, '4');
            testCase.verifyEqual(event.kind, "SETTING");
            testCase.verifyEqual(event.trnexePath, "C:\TRNSYS18\Exe\TrnEXE64.exe");
            testCase.verifyEqual(event.waitForGui, true);
            testCase.verifyClass(event.waitForGui, 'logical');
            testCase.verifyEqual(event.detectTimeoutMs, 300000);
            testCase.verifyClass(event.detectTimeoutMs, 'double');
            testCase.verifyEqual(event.severity, "Notice");
        end

        function rejectsNumericBooleans(testCase)
            %REJECTSNUMERICBOOLEANS JSON 0 and 1 are not booleans.

            for value = ["0", "1", """true"""]
                line = replace(settingLine(), '"waitForGui":true', ...
                    '"waitForGui":' + value);
                testCase.verifyError(@() trnrun.internal.parseStreamLine(line), ...
                    testCase.ParseError, line);
            end
        end

        function rejectsNonIntegerIntegers(testCase)
            %REJECTSNONINTEGERINTEGERS Millisecond fields must be whole numbers.

            line = replace(settingLine(), '"pollMs":100', '"pollMs":100.5');
            testCase.verifyError(@() trnrun.internal.parseStreamLine(line), ...
                testCase.ParseError);
        end

        function acceptsNegativeAndLargeIntegers(testCase)
            %ACCEPTSNEGATIVEANDLARGEINTEGERS Integrality is checked, not range.

            line = replace(settingLine(), '"watchTimeoutMs":0', ...
                '"watchTimeoutMs":-1');
            [~, event] = trnrun.internal.parseStreamLine(line);

            testCase.verifyEqual(event.watchTimeoutMs, -1);
        end

        % -----------------------------------------------------------------
        % LOG
        % -----------------------------------------------------------------

        function parsesFullLog(testCase)
            %PARSESFULLLOG A complete LOG event keeps every detail.

            [runId, event] = trnrun.internal.parseStreamLine( ...
                ['{"runID":"5","kind":"LOG","severity":"Warning","timestamp":"t",' ...
                 '"time":12.5,"unitID":3,"typeID":3830,"messageCode":42,' ...
                 '"message":"m","information":"i"}']);

            testCase.verifyEqual(runId, '5');
            testCase.verifyEqual(event, struct( ...
                'kind', "LOG", 'runID', "5", 'severity', "Warning", ...
                'timestamp', "t", 'time', 12.5, 'unitID', 3, 'typeID', 3830, ...
                'messageCode', 42, 'message', "m", 'information', "i"));
        end

        function defaultsOptionalLogDetails(testCase)
            %DEFAULTSOPTIONALLOGDETAILS Absent numbers are NaN and absent text missing.

            [~, event] = trnrun.internal.parseStreamLine( ...
                '{"runID":"5","kind":"LOG","severity":"Notice","timestamp":"t"}');

            testCase.verifyEqual(event.time, NaN);
            testCase.verifyEqual(event.unitID, NaN);
            testCase.verifyEqual(event.typeID, NaN);
            testCase.verifyEqual(event.messageCode, NaN);
            testCase.verifyTrue(ismissing(event.message));
            testCase.verifyTrue(ismissing(event.information));
        end

        function treatsJsonNullAndEmptyArrayAsAbsent(testCase)
            %TREATSJSONNULLANDEMPTYARRAYASABSENT Both decode to [] and take defaults.

            [~, event] = trnrun.internal.parseStreamLine( ...
                ['{"runID":"5","kind":"LOG","severity":"Notice","timestamp":"t",' ...
                 '"unitID":null,"messageCode":[],"information":null}']);

            testCase.verifyEqual(event.unitID, NaN);
            testCase.verifyEqual(event.messageCode, NaN);
            testCase.verifyTrue(ismissing(event.information));
        end

        function rejectsLogWithoutSeverity(testCase)
            %REJECTSLOGWITHOUTSEVERITY Severity and timestamp are required.

            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                '{"runID":"5","kind":"LOG","timestamp":"t"}'), testCase.ParseError);
            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                '{"runID":"5","kind":"LOG","severity":"Notice"}'), testCase.ParseError);
        end

        function rejectsNonIntegerLogDetail(testCase)
            %REJECTSNONINTEGERLOGDETAIL Present optional fields are still validated.

            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                ['{"runID":"5","kind":"LOG","severity":"Notice","timestamp":"t",' ...
                 '"unitID":1.5}']), testCase.ParseError);
        end

        % -----------------------------------------------------------------
        % QUEUE
        % -----------------------------------------------------------------

        function parsesQueueWithExitCode(testCase)
            %PARSESQUEUEWITHEXITCODE QUEUE is the only kind that requires event.

            [runId, event] = trnrun.internal.parseStreamLine( ...
                ['{"runID":"6","kind":"QUEUE","event":"COMPLETED",' ...
                 '"timestamp":"t","exitCode":0}']);

            testCase.verifyEqual(runId, '6');
            testCase.verifyEqual(event, struct( ...
                'kind', "QUEUE", 'event', "COMPLETED", 'runID', "6", ...
                'timestamp', "t", 'exitCode', 0));
        end

        function defaultsQueueExitCodeToNaN(testCase)
            %DEFAULTSQUEUEEXITCODETONAN A completion without an exit code is valid.

            [~, event] = trnrun.internal.parseStreamLine( ...
                '{"runID":"6","kind":"QUEUE","event":"ACCEPTED","timestamp":"t"}');

            testCase.verifyEqual(event.exitCode, NaN);
        end

        function rejectsQueueWithoutEvent(testCase)
            %REJECTSQUEUEWITHOUTEVENT QUEUE without a name cannot be routed.

            testCase.verifyError(@() trnrun.internal.parseStreamLine( ...
                '{"runID":"6","kind":"QUEUE","timestamp":"t"}'), testCase.ParseError);
        end

        % -----------------------------------------------------------------
        % Field layout
        % -----------------------------------------------------------------

        function keepsFieldOrderStableWithinKind(testCase)
            %KEEPSFIELDORDERSTABLEWITHINKIND Same-kind events must concatenate.

            [~, full] = trnrun.internal.parseStreamLine( ...
                ['{"runID":"5","kind":"LOG","severity":"Notice","timestamp":"t",' ...
                 '"time":1,"unitID":2,"typeID":3,"messageCode":4,"message":"m",' ...
                 '"information":"i"}']);
            [~, sparse] = trnrun.internal.parseStreamLine( ...
                '{"runID":"5","kind":"LOG","severity":"Fatal","timestamp":"t"}');

            testCase.verifyEqual(fieldnames(sparse), fieldnames(full));
            combined = [full, sparse];
            testCase.verifySize(combined, [1 2]);
            testCase.verifyEqual(combined(2).severity, "Fatal");
        end

        function returnsRunIdAsCharRow(testCase)
            %RETURNSRUNIDASCHARROW Callers compare the wire ID as text.

            [runId, ~] = trnrun.internal.parseStreamLine( ...
                '{"runID":"007","kind":"STATUS","status":"DONE","timestamp":"t"}');

            testCase.verifyClass(runId, 'char');
            testCase.verifyEqual(runId, '007');
        end
    end
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the toolbox folder next to this tests folder.

    folder = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox');
end

function line = settingLine()
    %SETTINGLINE Return a complete, valid SETTING event line.

    line = ['{"runID":"4","kind":"SETTING","timestamp":"t",' ...
        '"trnexePath":"C:\\TRNSYS18\\Exe\\TrnEXE64.exe",' ...
        '"guiVisibility":"hidden","waitForGui":true,"waitForLst":true,' ...
        '"waitForTmp":false,"detectTimeoutMs":300000,"extraDelayMs":0,' ...
        '"watchLog":true,"watchTmp":false,"watchTimeoutMs":0,' ...
        '"stallTimeoutMs":0,"pollMs":100,"cleanOnSuccess":false,' ...
        '"killOnTimeout":false,"killOnStall":false,"severity":"Notice",' ...
        '"writeEvents":false}'];
end
