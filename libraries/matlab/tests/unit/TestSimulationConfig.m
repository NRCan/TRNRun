classdef TestSimulationConfig < matlab.unittest.TestCase
    methods (Test)
        function defaultsAndCliOrderMatchContract(testCase)
            contract = jsondecode(fileread(fullfile( ...
                testsupport.fixtureRoot(), 'config_contract.json')));
            config = trnrun.SimulationConfig();

            names = fieldnames(contract.defaults);
            for index = 1:numel(names)
                name = names{index};
                if strcmp(name, 'trnrun_path')
                    testCase.verifyTrue(endsWith(config.trnrun_path, ...
                        fullfile('bin', 'win64', 'trnrun.exe')));
                elseif ischar(contract.defaults.(name))
                    testCase.verifyEqual(string(config.(name)), ...
                        string(contract.defaults.(name)));
                else
                    testCase.verifyEqual(config.(name), contract.defaults.(name));
                end
            end

            expected = cellstr(contract.defaultCliArgs);
            absolute_trnexe = trnrun.internal.absolutePath( ...
                config.trnexe_path, 'trnexe_path');
            expected = cellfun(@(value) strrep(value, ...
                '{absolute_trnexe_path}', char(absolute_trnexe)), ...
                expected, 'UniformOutput', false);
            args = config.to_cli_args();
            testCase.verifyClass(args, 'cell');
            testCase.verifySize(args, [1 numel(expected)]);
            testCase.verifyTrue(all(cellfun(@(arg) ischar(arg) && isrow(arg), args)));
            testCase.verifyEqual(args, expected(:)');
        end

        function serializesAllCustomValues(testCase)
            files = testsupport.TemporaryFiles();
            cleanup = onCleanup(@() delete(files)); %#ok<NASGU>
            config = trnrun.SimulationConfig( ...
                'trnrun_path', files.runner, ...
                'trnexe_path', files.trnexe, ...
                'gui_visibility', 'minAuto', ...
                'wait_for_gui', false, ...
                'wait_for_lst', false, ...
                'wait_for_tmp', true, ...
                'detect_timeout_ms', 1234, ...
                'extra_delay_ms', 55, ...
                'poll_ms', 7, ...
                'watch_log', false, ...
                'watch_tmp', true, ...
                'watch_timeout_ms', 9000, ...
                'stall_timeout_ms', 8000, ...
                'clean_on_success', true, ...
                'kill_on_timeout', true, ...
                'kill_on_stall', true, ...
                'severity', 'Fatal', ...
                'write_events', true);

            expected = {
                ['--trnexePath:' files.trnexe], '--guiVisibility:minAuto', ...
                '--waitForGui:false', '--waitForLst:false', '--waitForTmp:true', ...
                '--detectTimeout:1234', '--extraDelay:55', '--pollMs:7', ...
                '--watchLog:false', '--watchTmp:true', '--watchTimeout:9000', ...
                '--stallTimeout:8000', '--clean:true', '--killOnTimeout:true', ...
                '--killOnStall:true', '--severity:Fatal', '--writeEvents:true'};
            testCase.verifyEqual(config.to_cli_args(), expected);
        end

        function validatesAndResolvesExecutablePaths(testCase)
            files = testsupport.TemporaryFiles();
            cleanup = onCleanup(@() delete(files)); %#ok<NASGU>
            original = pwd;
            cd(files.root);
            restore = onCleanup(@() cd(original)); %#ok<NASGU>

            config = trnrun.SimulationConfig( ...
                'trnrun_path', 'trnrun.exe', ...
                'trnexe_path', 'TrnEXE64.exe');
            config = config.validate();
            testCase.verifyEqual(config.trnrun_path, string(files.runner));
            testCase.verifyEqual(config.trnexe_path, string(files.trnexe));
        end

        function constructorAcceptsNameValueSyntax(testCase)
            config = trnrun.SimulationConfig(watch_tmp=1, poll_ms=uint32(7));
            testCase.verifyEqual(config.watch_tmp, true);
            testCase.verifyEqual(config.poll_ms, 7);
            verifyRejects(testCase, @() trnrun.SimulationConfig('unknown_option', 1));
            verifyRejects(testCase, @() trnrun.SimulationConfig('poll_ms'));
        end

        function pathsAreStringScalars(testCase)
            names = {'trnrun_path', 'trnexe_path'};
            for index = 1:numel(names)
                name = names{index};
                config = trnrun.SimulationConfig();
                testCase.verifyClass(config.(name), 'string');
                testCase.verifySize(config.(name), [1 1]);
                for value = {'relative path/tool.exe', "other path/tool.exe"}
                    config = trnrun.SimulationConfig(name, value{1});
                    testCase.verifyEqual(config.(name), string(value{1}));
                    config.(name) = value{1};
                    testCase.verifyEqual(config.(name), string(value{1}));
                end
                for value = {"", string(missing), ["a", "b"]}
                    verifyRejects(testCase, @() trnrun.SimulationConfig(name, value{1}));
                    verifyRejects(testCase, @() assignProperty(config, name, value{1}));
                end
            end
        end

        function logicalPropertiesCoerceNumericZeroAndOne(testCase)
            names = {'wait_for_gui', 'wait_for_lst', 'wait_for_tmp', ...
                'watch_log', 'watch_tmp', 'clean_on_success', ...
                'kill_on_timeout', 'kill_on_stall', 'write_events'};
            for index = 1:numel(names)
                name = names{index};
                for value = {false, true, 0, 1}
                    config = trnrun.SimulationConfig(name, value{1});
                    testCase.verifyEqual(config.(name), logical(value{1}));
                    config.(name) = 1 - double(value{1});
                    testCase.verifyEqual(config.(name), ~logical(value{1}));
                end
                verifyRejects(testCase, @() trnrun.SimulationConfig(name, [true false]));
                verifyRejects(testCase, @() assignProperty(config, name, [true false]));
            end
            config = trnrun.SimulationConfig(watch_tmp=1, watch_log=0);
            args = config.to_cli_args();
            testCase.verifyTrue(ismember('--watchTmp:true', args));
            testCase.verifyTrue(ismember('--watchLog:false', args));
        end

        function integerPropertiesEnforceBoundsAtAssignment(testCase)
            names = {'detect_timeout_ms', 'extra_delay_ms', 'watch_timeout_ms', ...
                'stall_timeout_ms', 'poll_ms'};
            for index = 1:numel(names)
                name = names{index};
                minimum = double(strcmp(name, 'poll_ms'));
                for value = {minimum, uint32(7), 1e12}
                    config = trnrun.SimulationConfig(name, value{1});
                    testCase.verifyEqual(config.(name), double(value{1}));
                    config.(name) = uint32(9);
                    testCase.verifyEqual(config.(name), 9);
                end
                for value = {minimum - 1, Inf, -Inf, NaN, 1.5, [1 2]}
                    verifyRejects(testCase, @() trnrun.SimulationConfig(name, value{1}));
                    verifyRejects(testCase, @() assignProperty(config, name, value{1}));
                end
            end
            config = trnrun.SimulationConfig(detect_timeout_ms=1e12);
            testCase.verifyTrue(ismember('--detectTimeout:1000000000000', ...
                config.to_cli_args()));
        end

        function choicesRetainCaseInsensitiveAliases(testCase)
            names = {'gui_visibility', 'severity'};
            choices = {{'keep', 'keepopen', 'auto', 'autoclose', 'min', ...
                'minimized', 'minauto', 'minimizedauto', 'hidden'}, ...
                {'notice', 'warning', 'fatal'}};
            for index = 1:numel(names)
                name = names{index};
                for choice = choices{index}
                    for value = {choice{1}, string(upper(choice{1}))}
                        config = trnrun.SimulationConfig(name, value{1});
                        testCase.verifyEqual(string(config.(name)), string(value{1}));
                        config.(name) = value{1};
                        testCase.verifyEqual(string(config.(name)), string(value{1}));
                    end
                end
                for value = {'unsupported', '', ["hidden", "fatal"]}
                    verifyRejects(testCase, @() trnrun.SimulationConfig(name, value{1}));
                    verifyRejects(testCase, @() assignProperty(config, name, value{1}));
                end
            end
        end

        function validateRetainsExecutableChecks(testCase)
            files = testsupport.TemporaryFiles();
            cleanup = onCleanup(@() delete(files)); %#ok<NASGU>
            config = files.config();
            config.trnrun_path = fullfile(files.root, 'missing-runner.exe');
            testCase.verifyError(@() config.validate(), 'trnrun:RunnerNotFound');
            config = files.config();
            config.trnexe_path = fullfile(files.root, 'missing-trnexe.exe');
            testCase.verifyError(@() config.validate(), 'trnrun:TrnexeNotFound');
        end

        function assignmentsUseValueSemantics(testCase)
            original = trnrun.SimulationConfig();
            changed = original;
            changed.watch_tmp = true;
            testCase.verifyFalse(original.watch_tmp);
            testCase.verifyTrue(changed.watch_tmp);
        end
    end
end

function assignProperty(config, name, value)
config.(name) = value;
end

function verifyRejects(testCase, action)
% Native validation identifiers may differ between MATLAB releases.
rejected = false;
try
    action();
catch
    rejected = true;
end
testCase.verifyTrue(rejected, 'Expected invalid configuration input to be rejected.');
end
