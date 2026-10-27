classdef SimulationTest < matlab.unittest.TestCase
    %SIMULATIONTEST Unit tests for trnrun.Simulation and trnrun.SimulationSettings.

    methods (TestClassSetup)
        function addToolbox(testCase)
            %ADDTOOLBOX Put the toolbox on the path for the whole class.

            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox')));
        end
    end

    methods (Test)
        function parsesAFinishedSimulation(testCase)
            %PARSESAFINISHEDSIMULATION Every field of trnrund's README example.

            simulation = trnrun.Simulation(jsondecode(['{"simId":1,' ...
                '"label":"building-a","state":"FINISHED","trnrunStatus":"DONE",' ...
                '"trnrunMessage":"","percent":1.0,"simTime":8760.0,' ...
                '"elapsedMs":5321.0,"etaMs":0.0,"notices":2,"warnings":1,' ...
                '"fatals":0,"succeeded":true,"exitCode":0,"error":null,' ...
                '"submittedAt":"2026-10-22T14:03:12.345Z",' ...
                '"startedAt":"2026-10-22T14:03:12.351Z",' ...
                '"finishedAt":"2026-10-22T14:03:17.702Z",' ...
                '"deckFile":"C:\\models\\building-a.dck",' ...
                '"trnrunArgs":["--guiVisibility:min","--watchTmp:true"],' ...
                '"startTime":0.0,"stopTime":8760.0,"timeStep":1.0,' ...
                '"setting":{"watchTmp":true},"logs":[{"severity":"Warning",' ...
                '"time":12.0,"unitId":5,"typeId":56,"messageCode":null,' ...
                '"message":"careful","information":null}]}']));

            testCase.verifyEqual(simulation.simId, 1);
            testCase.verifyEqual(simulation.label, "building-a");
            testCase.verifyEqual(simulation.state, "FINISHED");
            testCase.verifyEqual(simulation.deckFile, "C:\models\building-a.dck");
            testCase.verifyEqual(simulation.trnrunArgs, ...
                ["--guiVisibility:min", "--watchTmp:true"]);
            testCase.verifyEqual(simulation.trnrunMessage, "");
            testCase.verifyEqual(simulation.stopTime, 8760);
            testCase.verifyTrue(simulation.succeeded);
            testCase.verifyTrue(ismissing(simulation.error));
            testCase.verifyEqual(seconds(simulation.finishedAt - simulation.startedAt), ...
                5.351, 'AbsTol', 1e-6);
            testCase.verifyEqual(simulation.submittedAt.TimeZone, 'UTC');
            testCase.verifyTrue(simulation.setting.watchTmp);
            testCase.verifyEqual(simulation.logs(1).message, 'careful');
            testCase.verifyEmpty(simulation.logs(1).messageCode);
        end

        function parsesNullsAsMissingValues(testCase)
            %PARSESNULLSASMISSINGVALUES A value TRNRun has not reported is missing, NaN or NaT.

            simulation = trnrun.Simulation(jsondecode(['{"simId":2,' ...
                '"label":null,"state":"QUEUED","trnrunStatus":null,' ...
                '"trnrunMessage":null,"percent":null,"simTime":null,' ...
                '"elapsedMs":null,"etaMs":null,"notices":0,"warnings":0,' ...
                '"fatals":0,"succeeded":null,"exitCode":null,"error":null,' ...
                '"submittedAt":"2026-10-22T14:03:12.345Z","startedAt":null,' ...
                '"finishedAt":null,"deckFile":"C:\\a.dck","trnrunArgs":[],' ...
                '"startTime":null,"stopTime":null,"timeStep":null,' ...
                '"setting":null}']));

            testCase.verifyTrue(ismissing(simulation.label));
            testCase.verifyTrue(ismissing(simulation.trnrunStatus));
            testCase.verifyTrue(isnan(simulation.percent));
            testCase.verifyTrue(isnan(simulation.exitCode));
            testCase.verifyFalse(simulation.succeeded);
            testCase.verifyTrue(isnat(simulation.startedAt));
            testCase.verifyEqual(simulation.startedAt.TimeZone, 'UTC');
            testCase.verifySize(simulation.trnrunArgs, [1 0]);
            testCase.verifyEmpty(simulation.logs);
        end

        function settingsPassOnlyTheFlagsThatAreSet(testCase)
            %SETTINGSPASSONLYTHEFLAGSTHATARESET An empty property keeps TRNRun's default.

            defaults = trnrun.SimulationSettings();
            testCase.verifyEqual(defaults.cliArgs(), cell(1, 0));

            settings = trnrun.SimulationSettings(guiVisibility='min', ...
                watchTmp=true, waitForGui=false, stallTimeout=60000);

            testCase.verifyEqual(settings.cliArgs(), {'--guiVisibility:min', ...
                '--waitForGui:false', '--watchTmp:true', '--stallTimeout:60000'});
        end

        function settingsResolveTheTrnsysExecutable(testCase)
            %SETTINGSRESOLVETHETRNSYSEXECUTABLE trnexePath must exist and is made absolute.

            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            testCase.applyFixture(matlab.unittest.fixtures.CurrentFolderFixture(folder));
            fclose(fopen(fullfile(folder, 'TrnEXE64.exe'), 'w'));

            present = trnrun.SimulationSettings(trnexePath='TrnEXE64.exe');
            absent = trnrun.SimulationSettings(trnexePath='absent.exe');

            testCase.verifyEqual(present.cliArgs(), ...
                {['--trnexePath:' fullfile(folder, 'TrnEXE64.exe')]});
            testCase.verifyError(@() absent.cliArgs(), 'MATLAB:validators:mustBeFile');
        end

        function settingsRejectInvalidValues(testCase)
            %SETTINGSREJECTINVALIDVALUES Types and ranges are checked on assignment.

            testCase.verifyError(@() trnrun.SimulationSettings(pollMs=0), ...
                'MATLAB:validators:mustBePositive');
            testCase.verifyError(@() trnrun.SimulationSettings(detectTimeout=1.5), ...
                'MATLAB:validators:mustBeInteger');
            testCase.verifyError(@() trnrun.SimulationSettings(watchTmp=[true false]), ...
                'MATLAB:validators:mustBeScalarOrEmpty');
            testCase.verifyError(@() trnrun.SimulationSettings(guiVisibility="hiden"), ...
                'MATLAB:validators:mustBeMember');
            testCase.verifyError(@() trnrun.SimulationSettings(severity="Error"), ...
                'MATLAB:validators:mustBeMember');
        end
    end
end
