classdef SimulationConfigTest < matlab.unittest.TestCase
    %SIMULATIONCONFIGTEST Unit tests for trnrun.SimulationConfig.
    %   Covers defaults, property validation, value semantics, path
    %   resolution in validate, and the runner command line.

    properties
        Runner (1,1) string
        TrnExe (1,1) string
    end

    methods (TestClassSetup)
        function addToolbox(testCase)
            %ADDTOOLBOX Put the toolbox on the path for the whole class.

            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                toolboxFolder()));
        end
    end

    methods (TestMethodSetup)
        function createExecutables(testCase)
            %CREATEEXECUTABLES Create harmless stand-ins for the two executables.

            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            testCase.Runner = fullfile(folder, "trnrun.exe");
            testCase.TrnExe = fullfile(folder, "TrnEXE64.exe");
            for path = [testCase.Runner, testCase.TrnExe]
                fid = fopen(path, 'w');
                fclose(fid);
            end
        end
    end

    methods (Test)
        % -----------------------------------------------------------------
        % Defaults
        % -----------------------------------------------------------------

        function defaultsMatchRunnerDefaults(testCase)
            %DEFAULTSMATCHRUNNERDEFAULTS An unconfigured launch is hidden and safe.

            config = trnrun.SimulationConfig();

            testCase.verifyEqual(config.trnexe_path, "C:\TRNSYS18\Exe\TrnEXE64.exe");
            testCase.verifyEqual(config.gui_visibility, "hidden");
            testCase.verifyTrue(config.wait_for_gui);
            testCase.verifyTrue(config.wait_for_lst);
            testCase.verifyFalse(config.wait_for_tmp);
            testCase.verifyEqual(config.detect_timeout_ms, 300000);
            testCase.verifyEqual(config.extra_delay_ms, 0);
            testCase.verifyEqual(config.poll_ms, 100);
            testCase.verifyTrue(config.watch_log);
            testCase.verifyFalse(config.watch_tmp);
            testCase.verifyEqual(config.watch_timeout_ms, 0);
            testCase.verifyEqual(config.stall_timeout_ms, 0);
            testCase.verifyFalse(config.clean_on_success);
            testCase.verifyFalse(config.kill_on_timeout);
            testCase.verifyFalse(config.kill_on_stall);
            testCase.verifyEqual(config.severity, "Notice");
            testCase.verifyFalse(config.write_events);
        end

        function defaultRunnerPathPointsAtBundledExecutable(testCase)
            %DEFAULTRUNNERPATHPOINTSATBUNDLEDEXECUTABLE bin/trnrun.exe ships with the toolbox.

            config = trnrun.SimulationConfig();
            expected = fullfile(toolboxFolder(), 'bin', 'trnrun.exe');

            testCase.verifyEqual(config.trnrun_path, string(expected));
            testCase.verifyTrue(isfile(config.trnrun_path), ...
                'The toolbox must ship the runner it defaults to.');
        end

        % -----------------------------------------------------------------
        % Construction
        % -----------------------------------------------------------------

        function constructorAppliesNamedOptions(testCase)
            %CONSTRUCTORAPPLIESNAMEDOPTIONS Named values override the defaults.

            config = trnrun.SimulationConfig( ...
                watch_tmp=true, stall_timeout_ms=60000, severity="Fatal", ...
                gui_visibility="minAuto", poll_ms=250);

            testCase.verifyTrue(config.watch_tmp);
            testCase.verifyEqual(config.stall_timeout_ms, 60000);
            testCase.verifyEqual(config.severity, "Fatal");
            testCase.verifyEqual(config.gui_visibility, "minAuto");
            testCase.verifyEqual(config.poll_ms, 250);
        end

        function constructorConvertsInputsToPropertyTypes(testCase)
            %CONSTRUCTORCONVERTSINPUTSTOPROPERTYTYPES Char and numeric inputs are coerced.

            config = trnrun.SimulationConfig( ...
                trnexe_path='C:\TRNSYS17\Exe\TrnEXE.exe', ...
                gui_visibility='keep', wait_for_gui=0, watch_log=1);

            testCase.verifyClass(config.trnexe_path, 'string');
            testCase.verifyEqual(config.trnexe_path, "C:\TRNSYS17\Exe\TrnEXE.exe");
            testCase.verifyClass(config.gui_visibility, 'string');
            testCase.verifyClass(config.wait_for_gui, 'logical');
            testCase.verifyFalse(config.wait_for_gui);
            testCase.verifyTrue(config.watch_log);
        end

        function constructorRejectsUnknownOption(testCase)
            %CONSTRUCTORREJECTSUNKNOWNOPTION Options are listed explicitly, not forwarded.

            testCase.verifyError(@() trnrun.SimulationConfig(watchTmp=true), ...
                'MATLAB:TooManyInputs');
        end

        function isValueClass(testCase)
            %ISVALUECLASS Each submitted run must keep an independent copy.

            original = trnrun.SimulationConfig();
            copy = original;
            copy.poll_ms = 500;

            testCase.verifyEqual(original.poll_ms, 100);
            testCase.verifyEqual(copy.poll_ms, 500);
            testCase.verifyFalse(isa(original, 'handle'));
        end

        % -----------------------------------------------------------------
        % Property validation
        % -----------------------------------------------------------------

        function acceptsEveryGuiVisibilityAliasIgnoringCase(testCase)
            %ACCEPTSEVERYGUIVISIBILITYALIASIGNORINGCASE Text choices are case-insensitive.

            aliases = ["keep", "keepOpen", "auto", "autoClose", "min", ...
                "minimized", "minAuto", "minimizedAuto", "hidden", ...
                "HIDDEN", "Keep"];
            for alias = aliases
                config = trnrun.SimulationConfig(gui_visibility=alias);
                testCase.verifyEqual(config.gui_visibility, alias, ...
                    'The original spelling must reach the runner.');
            end
        end

        function acceptsEverySeverityIgnoringCase(testCase)
            %ACCEPTSEVERYSEVERITYIGNORINGCASE Severity spelling is preserved.

            for severity = ["Notice", "warning", "FATAL"]
                config = trnrun.SimulationConfig(severity=severity);
                testCase.verifyEqual(config.severity, severity);
            end
        end

        function rejectsUnsupportedTextChoices(testCase)
            %REJECTSUNSUPPORTEDTEXTCHOICES Unknown window modes and severities fail early.

            testCase.verifyError(@() trnrun.SimulationConfig(gui_visibility="maximized"), ...
                'MATLAB:validators:mustBeMember');
            testCase.verifyError(@() trnrun.SimulationConfig(severity="Debug"), ...
                'MATLAB:validators:mustBeMember');
            testCase.verifyError(@() trnrun.SimulationConfig(severity=""), ...
                'MATLAB:validators:mustBeMember');
        end

        function rejectsEmptyAndMissingPaths(testCase)
            %REJECTSEMPTYANDMISSINGPATHS A path property always holds real text.

            testCase.verifyError(@() trnrun.SimulationConfig(trnrun_path=""), ...
                'MATLAB:validators:mustBeNonzeroLengthText');
            testCase.verifyError(@() trnrun.SimulationConfig(trnexe_path=string(missing)), ...
                'MATLAB:validators:mustBeNonmissing');
        end

        function rejectsInvalidTimeouts(testCase)
            %REJECTSINVALIDTIMEOUTS Millisecond options are nonnegative whole numbers.

            testCase.verifyError(@() trnrun.SimulationConfig(detect_timeout_ms=-1), ...
                'MATLAB:validators:mustBeNonnegative');
            testCase.verifyError(@() trnrun.SimulationConfig(extra_delay_ms=1.5), ...
                'MATLAB:validators:mustBeInteger');
            testCase.verifyError(@() trnrun.SimulationConfig(watch_timeout_ms=NaN), ...
                'MATLAB:validators:mustBeInteger');
        end

        function rejectsNonPositivePollInterval(testCase)
            %REJECTSNONPOSITIVEPOLLINTERVAL A zero poll interval would spin.

            testCase.verifyError(@() trnrun.SimulationConfig(poll_ms=0), ...
                'MATLAB:validators:mustBePositive');
            testCase.verifyError(@() trnrun.SimulationConfig(poll_ms=-5), ...
                'MATLAB:validators:mustBePositive');
        end

        function acceptsZeroTimeoutsAsUnlimited(testCase)
            %ACCEPTSZEROTIMEOUTSASUNLIMITED Zero disables detection and stall limits.

            config = trnrun.SimulationConfig( ...
                detect_timeout_ms=0, watch_timeout_ms=0, stall_timeout_ms=0);

            testCase.verifyEqual(config.detect_timeout_ms, 0);
            testCase.verifyEqual(config.watch_timeout_ms, 0);
            testCase.verifyEqual(config.stall_timeout_ms, 0);
        end

        function validatesOnAssignmentAsWellAsConstruction(testCase)
            %VALIDATESONASSIGNMENTASWELLASCONSTRUCTION Property validators always run.

            config = trnrun.SimulationConfig();

            testCase.verifyError(@() setProperty(config, 'severity', "loud"), ...
                'MATLAB:validators:mustBeMember');
            testCase.verifyError(@() setProperty(config, 'poll_ms', 0), ...
                'MATLAB:validators:mustBePositive');
        end

        % -----------------------------------------------------------------
        % validate
        % -----------------------------------------------------------------

        function validateResolvesPathsToAbsolute(testCase)
            %VALIDATERESOLVESPATHSTOABSOLUTE Relative input becomes a full path.

            folder = fileparts(testCase.Runner);
            testCase.applyFixture( ...
                matlab.unittest.fixtures.CurrentFolderFixture(folder));

            config = trnrun.SimulationConfig( ...
                trnrun_path="trnrun.exe", trnexe_path="TrnEXE64.exe");
            config = config.validate();

            testCase.verifyTrue(isAbsolutePath(config.trnrun_path));
            testCase.verifyTrue(isAbsolutePath(config.trnexe_path));
            testCase.verifyTrue(isfile(config.trnrun_path));
            testCase.verifyTrue(isfile(config.trnexe_path));
        end

        function validateReturnsNewValueWithoutMutatingInput(testCase)
            %VALIDATERETURNSNEWVALUEWITHOUTMUTATINGINPUT Value semantics survive validation.

            original = trnrun.SimulationConfig( ...
                trnrun_path=testCase.Runner, trnexe_path=testCase.TrnExe);
            validated = original.validate();

            testCase.verifyEqual(original.trnrun_path, testCase.Runner);
            testCase.verifyEqual(validated.trnrun_path, testCase.Runner);
            testCase.verifyClass(validated, 'trnrun.SimulationConfig');
        end

        function validateRejectsMissingExecutables(testCase)
            %VALIDATEREJECTSMISSINGEXECUTABLES Both executables must exist before launch.

            missingRunner = trnrun.SimulationConfig( ...
                trnrun_path=fullfile(fileparts(testCase.Runner), "absent.exe"), ...
                trnexe_path=testCase.TrnExe);
            missingTrnExe = trnrun.SimulationConfig( ...
                trnrun_path=testCase.Runner, ...
                trnexe_path=fullfile(fileparts(testCase.Runner), "absent.exe"));

            testCase.verifyError(@() missingRunner.validate(), ...
                'MATLAB:validators:mustBeFile');
            testCase.verifyError(@() missingTrnExe.validate(), ...
                'MATLAB:validators:mustBeFile');
        end

        function validateRejectsFolderInPlaceOfExecutable(testCase)
            %VALIDATEREJECTSFOLDERINPLACEOFEXECUTABLE A folder is not a runnable file.

            config = trnrun.SimulationConfig( ...
                trnrun_path=fileparts(testCase.Runner), trnexe_path=testCase.TrnExe);

            testCase.verifyError(@() config.validate(), ...
                'MATLAB:validators:mustBeFile');
        end

        % -----------------------------------------------------------------
        % to_cli_args
        % -----------------------------------------------------------------

        function cliArgsAreCharCellRow(testCase)
            %CLIARGSARECHARCELLROW jsonencode must serialise the args as a JSON array.

            args = trnrun.SimulationConfig().to_cli_args();

            testCase.verifyClass(args, 'cell');
            testCase.verifySize(args, [1 17]);
            testCase.verifyTrue(all(cellfun(@ischar, args)));
            testCase.verifyEqual(jsonencode(args(1:2)), ...
                ['["--trnexePath:C:\\TRNSYS18\\Exe\\TrnEXE64.exe",' ...
                 '"--guiVisibility:hidden"]']);
        end

        function cliArgsMatchDefaults(testCase)
            %CLIARGSMATCHDEFAULTS The default command line is fully specified.

            args = trnrun.SimulationConfig().to_cli_args();

            testCase.verifyEqual(args, { ...
                '--trnexePath:C:\TRNSYS18\Exe\TrnEXE64.exe', ...
                '--guiVisibility:hidden', ...
                '--waitForGui:true', ...
                '--waitForLst:true', ...
                '--waitForTmp:false', ...
                '--detectTimeout:300000', ...
                '--extraDelay:0', ...
                '--pollMs:100', ...
                '--watchLog:true', ...
                '--watchTmp:false', ...
                '--watchTimeout:0', ...
                '--stallTimeout:0', ...
                '--clean:false', ...
                '--killOnTimeout:false', ...
                '--killOnStall:false', ...
                '--severity:Notice', ...
                '--writeEvents:false'});
        end

        function cliArgsRenderLogicalsAsWords(testCase)
            %CLIARGSRENDERLOGICALSASWORDS The runner expects true and false, not 1 and 0.

            args = trnrun.SimulationConfig(watch_tmp=true, watch_log=false, ...
                clean_on_success=true, kill_on_timeout=true, ...
                kill_on_stall=true, write_events=true).to_cli_args();

            testCase.verifyTrue(ismember('--watchTmp:true', args));
            testCase.verifyTrue(ismember('--watchLog:false', args));
            testCase.verifyTrue(ismember('--clean:true', args));
            testCase.verifyTrue(ismember('--killOnTimeout:true', args));
            testCase.verifyTrue(ismember('--killOnStall:true', args));
            testCase.verifyTrue(ismember('--writeEvents:true', args));
        end

        function cliArgsAvoidScientificNotation(testCase)
            %CLIARGSAVOIDSCIENTIFICNOTATION Large millisecond values stay literal.

            args = trnrun.SimulationConfig( ...
                detect_timeout_ms=1e10, watch_timeout_ms=100000, ...
                stall_timeout_ms=86400000, extra_delay_ms=1e6).to_cli_args();

            testCase.verifyTrue(ismember('--detectTimeout:10000000000', args));
            testCase.verifyTrue(ismember('--watchTimeout:100000', args));
            testCase.verifyTrue(ismember('--stallTimeout:86400000', args));
            testCase.verifyTrue(ismember('--extraDelay:1000000', args));
        end

        function cliArgsAreUnquoted(testCase)
            %CLIARGSAREUNQUOTED Quoting belongs to the process launcher, not the config.

            spaced = "C:\Program Files\TRNSYS18\Exe\TrnEXE64.exe";
            args = trnrun.SimulationConfig(trnexe_path=spaced).to_cli_args();

            testCase.verifyEqual(args{1}, char("--trnexePath:" + spaced));
            testCase.verifyFalse(contains(args{1}, '"'));
        end

        function cliArgsOmitRunnerPath(testCase)
            %CLIARGSOMITRUNNERPATH trnrun_path selects the executable, not an option.

            args = trnrun.SimulationConfig(trnrun_path=testCase.Runner).to_cli_args();

            testCase.verifyFalse(any(contains(args, 'trnrunPath')));
            testCase.verifyFalse(any(contains(args, char(testCase.Runner))));
        end
    end
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the toolbox folder next to this tests folder.

    folder = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox');
end

function setProperty(config, name, value)
    %SETPROPERTY Assign a property so validators run inside a testable call.

    config.(name) = value;
end

function tf = isAbsolutePath(path)
    %ISABSOLUTEPATH Identify a rooted Windows path.

    tf = ~isempty(regexp(char(path), '^([A-Za-z]:[\\/]|\\\\)', 'once'));
end
