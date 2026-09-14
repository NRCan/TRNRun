classdef SimulationTest < matlab.unittest.TestCase
    %SIMULATIONTEST Unit tests for trnrun.Simulation.
    %   Covers construction, event folding, severity tallies, lifecycle
    %   stage, and the separation of queue completion from runner outcome.

    properties
        Config
    end

    methods (TestClassSetup)
        function addToolbox(testCase)
            %ADDTOOLBOX Put the toolbox on the path for the whole class.

            testCase.applyFixture(matlab.unittest.fixtures.PathFixture( ...
                toolboxFolder()));
        end
    end

    methods (TestMethodSetup)
        function createConfig(testCase)
            %CREATECONFIG Share one default configuration across the tests.

            testCase.Config = trnrun.SimulationConfig();
        end
    end

    methods (Test)
        % -----------------------------------------------------------------
        % Construction
        % -----------------------------------------------------------------

        function constructorStoresIdentity(testCase)
            %CONSTRUCTORSTORESIDENTITY The deck, config and ID are fixed at creation.

            simulation = trnrun.Simulation("C:\runs\model.dck", testCase.Config, 7);

            testCase.verifyEqual(simulation.id, 7);
            testCase.verifyEqual(simulation.deckPath, "C:\runs\model.dck");
            testCase.verifyEqual(simulation.config, testCase.Config);
            testCase.verifyClass(simulation, 'trnrun.Simulation');
        end

        function constructorAcceptsCharDeckPath(testCase)
            %CONSTRUCTORACCEPTSCHARDECKPATH Property validation converts the deck path.

            simulation = trnrun.Simulation('model.dck', testCase.Config, 1);

            testCase.verifyClass(simulation.deckPath, 'string');
            testCase.verifyEqual(simulation.deckPath, "model.dck");
        end

        function constructorRejectsInvalidConfig(testCase)
            %CONSTRUCTORREJECTSINVALIDCONFIG The offending argument is named directly.

            testCase.verifyError(@() trnrun.Simulation("a.dck", struct(), 1), ...
                'trnrun:InvalidConfig');
            testCase.verifyError(@() trnrun.Simulation("a.dck", "config", 1), ...
                'trnrun:InvalidConfig');
            testCase.verifyError(@() trnrun.Simulation("a.dck", ...
                [testCase.Config, testCase.Config], 1), 'trnrun:InvalidConfig');
        end

        function constructorRejectsInvalidRunId(testCase)
            %CONSTRUCTORREJECTSINVALIDRUNID IDs are positive integer-valued scalars.

            invalid = {0, -1, 1.5, NaN, Inf, [1 2], [], '1', "1", true, 1 + 2i};
            for index = 1:numel(invalid)
                testCase.verifyError( ...
                    @() trnrun.Simulation("a.dck", testCase.Config, invalid{index}), ...
                    'trnrun:InvalidInteger', sprintf('input %d', index));
            end
        end

        function constructorAcceptsIntegerValuedDouble(testCase)
            %CONSTRUCTORACCEPTSINTEGERVALUEDDOUBLE Queue IDs arrive as doubles.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 12);

            testCase.verifyEqual(simulation.id, 12);
            testCase.verifyClass(simulation.id, 'double');
        end

        function identityPropertiesAreImmutable(testCase)
            %IDENTITYPROPERTIESAREIMMUTABLE Routing must not change after submission.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);

            testCase.verifyError(@() setProperty(simulation, 'id', 2), ...
                'MATLAB:class:SetProhibited');
            testCase.verifyError(@() setProperty(simulation, 'deckPath', "b.dck"), ...
                'MATLAB:class:SetProhibited');
        end

        function eventStateIsReadOnlyFromOutside(testCase)
            %EVENTSTATEISREADONLYFROMOUTSIDE Only the manager folds in updates.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);

            testCase.verifyError(@() setProperty(simulation, 'isAccepted', true), ...
                'MATLAB:class:SetProhibited');
            testCase.verifyError(@() setProperty(simulation, 'logCount', 5), ...
                'MATLAB:class:SetProhibited');
        end

        function isHandleClass(testCase)
            %ISHANDLECLASS Callers observe live updates through a shared handle.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            alias = simulation;
            alias.markAccepted();

            testCase.verifyTrue(isa(simulation, 'handle'));
            testCase.verifyTrue(simulation.isAccepted);
            testCase.verifyTrue(simulation == alias);
        end

        % -----------------------------------------------------------------
        % Initial state
        % -----------------------------------------------------------------

        function newSimulationIsPending(testCase)
            %NEWSIMULATIONISPENDING Nothing is known until the queue responds.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);

            testCase.verifyEqual(simulation.state, 'pending');
            testCase.verifyFalse(simulation.isAccepted);
            testCase.verifyTrue(simulation.isRunning);
            testCase.verifyFalse(simulation.isFinished);
            testCase.verifyFalse(simulation.hasTerminalStatus);
            testCase.verifyFalse(simulation.succeeded);
            testCase.verifyEmpty(simulation.status);
            testCase.verifyEmpty(simulation.progress);
            testCase.verifyEmpty(simulation.configEvent);
            testCase.verifyEmpty(simulation.settingEvent);
            testCase.verifyEmpty(simulation.completionEvent);
            testCase.verifyEqual(simulation.logCount, 0);
            testCase.verifyEqual(simulation.notices, 0);
            testCase.verifyEqual(simulation.warnings, 0);
            testCase.verifyEqual(simulation.fatals, 0);
        end

        function terminalStatusesAreTheDocumentedSet(testCase)
            %TERMINALSTATUSESARETHEDOCUMENTEDSET Runner outcomes are a closed set.

            testCase.verifyEqual(trnrun.Simulation.TerminalStatuses, ...
                ["DONE" "ERROR" "CANCELLED" "TIMEOUT" "STALLED"]);
        end

        % -----------------------------------------------------------------
        % Lifecycle stage
        % -----------------------------------------------------------------

        function acceptanceMovesToRunning(testCase)
            %ACCEPTANCEMOVESTORUNNING A worker has picked up the run.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.markAccepted();

            testCase.verifyTrue(simulation.isAccepted);
            testCase.verifyEqual(simulation.state, 'running');
            testCase.verifyTrue(simulation.isRunning);
        end

        function completionMovesToFinishedEvenWithoutAcceptance(testCase)
            %COMPLETIONMOVESTOFINISHEDEVENWITHOUTACCEPTANCE Completion wins over acceptance.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.markCompleted(completionEvent());

            testCase.verifyEqual(simulation.state, 'finished');
            testCase.verifyTrue(simulation.isFinished);
            testCase.verifyFalse(simulation.isRunning);
            testCase.verifyFalse(simulation.isAccepted);
        end

        function runnerStatusDoesNotChangeStage(testCase)
            %RUNNERSTATUSDOESNOTCHANGESTAGE Only queue events move the lifecycle.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.markAccepted();
            simulation.applyEvent(statusEvent("DONE"));

            testCase.verifyEqual(simulation.state, 'running');
            testCase.verifyTrue(simulation.hasTerminalStatus);
            testCase.verifyFalse(simulation.succeeded);
        end

        % -----------------------------------------------------------------
        % applyEvent
        % -----------------------------------------------------------------

        function retainsLatestStatusProgressConfigAndSetting(testCase)
            %RETAINSLATESTSTATUSPROGRESSCONFIGANDSETTING Snapshot events keep the newest.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(statusEvent("PENDING"));
            simulation.applyEvent(statusEvent("RUNNING"));
            simulation.applyEvent(struct('kind', "PROGRESS", 'percent', 0.1, ...
                'time', 100, 'elapsed', 10, 'eta', 90));
            simulation.applyEvent(struct('kind', "PROGRESS", 'percent', 0.9, ...
                'time', 900, 'elapsed', 90, 'eta', 10));
            simulation.applyEvent(struct('kind', "CONFIG", 'start', 0, ...
                'stop', 8760, 'step', 0.125));
            simulation.applyEvent(struct('kind', "SETTING", 'pollMs', 100));

            testCase.verifyEqual(simulation.status.status, "RUNNING");
            testCase.verifyEqual(simulation.progress.percent, 0.9);
            testCase.verifyEqual(simulation.configEvent.stop, 8760);
            testCase.verifyEqual(simulation.settingEvent.pollMs, 100);
        end

        function accumulatesLogsOldestFirst(testCase)
            %ACCUMULATESLOGSOLDESTFIRST The whole log history is retained in order.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(logEvent("Notice", "first"));
            simulation.applyEvent(logEvent("Warning", "second"));
            simulation.applyEvent(logEvent("Fatal", "third"));

            testCase.verifyEqual(simulation.logCount, 3);
            testCase.verifySize(simulation.logs, [1 3]);
            testCase.verifyEqual([simulation.logs.message], ...
                ["first", "second", "third"]);
        end

        function tallySeverityIgnoresCase(testCase)
            %TALLYSEVERITYIGNORESCASE Runner casing must not skew the totals.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            for severity = ["Notice", "notice", "NOTICE", "Warning", "fatal"]
                simulation.applyEvent(logEvent(severity, "m"));
            end

            testCase.verifyEqual(simulation.notices, 3);
            testCase.verifyEqual(simulation.warnings, 1);
            testCase.verifyEqual(simulation.fatals, 1);
            testCase.verifyEqual(simulation.logCount, 5);
        end

        function unrecognizedSeveritiesCountOnlyTowardsLogCount(testCase)
            %UNRECOGNIZEDSEVERITIESCOUNTONLYTOWARDSLOGCOUNT Unknown severities are still logs.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(logEvent("Debug", "m"));
            simulation.applyEvent(logEvent("", "m"));
            simulation.applyEvent(logEvent(string(missing), "m"));

            testCase.verifyEqual(simulation.logCount, 3);
            testCase.verifyEqual(simulation.notices, 0);
            testCase.verifyEqual(simulation.warnings, 0);
            testCase.verifyEqual(simulation.fatals, 0);
        end

        function logsWithoutASeverityFieldStillCount(testCase)
            %LOGSWITHOUTASEVERITYFIELDSTILLCOUNT An absent severity is tallied by count alone.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(rmfield(logEvent("Notice", "m"), 'severity'));

            testCase.verifyEqual(simulation.logCount, 1);
            testCase.verifyEqual(simulation.notices, 0);
            testCase.verifyFalse(isfield(simulation.logs, 'severity'));
        end

        function ignoresUnknownEventKinds(testCase)
            %IGNORESUNKNOWNEVENTKINDS Future event kinds must not break folding.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(struct('kind', "HEARTBEAT", 'beat', 1));

            testCase.verifyEmpty(simulation.status);
            testCase.verifyEqual(simulation.logCount, 0);
        end

        function ignoresEventsAfterCompletion(testCase)
            %IGNORESEVENTSAFTERCOMPLETION A finished run is a stable record.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(statusEvent("RUNNING"));
            simulation.markCompleted(completionEvent());
            simulation.applyEvent(statusEvent("DONE"));
            simulation.applyEvent(logEvent("Fatal", "late"));

            testCase.verifyEqual(simulation.status.status, "RUNNING");
            testCase.verifyEqual(simulation.logCount, 0);
            testCase.verifyFalse(simulation.succeeded);
        end

        % -----------------------------------------------------------------
        % logTable
        % -----------------------------------------------------------------

        function logTableIsEmptyWithoutLogs(testCase)
            %LOGTABLEISEMPTYWITHOUTLOGS No log schema exists before the first log.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            value = simulation.logTable();

            testCase.verifyClass(value, 'table');
            testCase.verifyEqual(height(value), 0);
            testCase.verifyEqual(width(value), 0);
        end

        function logTablePreservesFieldsAndOrder(testCase)
            %LOGTABLEPRESERVESFIELDSANDORDER Values reach the table unchanged.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(logEvent("Notice", "first"));
            simulation.applyEvent(logEvent("Fatal", "second"));
            value = simulation.logTable();

            testCase.verifyEqual(height(value), 2);
            testCase.verifyEqual(string(value.Properties.VariableNames), ...
                string(fieldnames(simulation.logs))');
            testCase.verifyEqual(value.message, ["first"; "second"]);
            testCase.verifyEqual(value.severity, ["Notice"; "Fatal"]);
        end

        function logTableHandlesSingleLog(testCase)
            %LOGTABLEHANDLESSINGLELOG One log is a one-row table, not a column of fields.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(logEvent("Notice", "only"));
            value = simulation.logTable();

            testCase.verifyEqual(height(value), 1);
            testCase.verifyEqual(value.message, "only");
        end

        % -----------------------------------------------------------------
        % markCompleted
        % -----------------------------------------------------------------

        function markCompletedRetainsEvent(testCase)
            %MARKCOMPLETEDRETAINSEVENT The completion event stays available to callers.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            event = completionEvent(3);
            simulation.markCompleted(event);

            testCase.verifyEqual(simulation.completionEvent, event);
            testCase.verifyEqual(simulation.completionEvent.exitCode, 3);
        end

        function markCompletedAcceptsCompletionWithoutExitCode(testCase)
            %MARKCOMPLETEDACCEPTSCOMPLETIONWITHOUTEXITCODE exitCode is optional on the wire.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.markCompleted(struct('kind', "QUEUE", 'event', "COMPLETED"));

            testCase.verifyTrue(simulation.isFinished);
        end

        function markCompletedRejectsOtherEvents(testCase)
            %MARKCOMPLETEDREJECTSOTHEREVENTS Only QUEUE/COMPLETED finishes a run.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            rejected = { ...
                struct('kind', "QUEUE", 'event', "ACCEPTED"), ...
                struct('kind', "STATUS", 'event', "COMPLETED"), ...
                struct('kind', "QUEUE"), ...
                struct('event', "COMPLETED"), ...
                struct([]), ...
                repmat(struct('kind', "QUEUE", 'event', "COMPLETED"), 1, 2), ...
                'COMPLETED'};
            for index = 1:numel(rejected)
                testCase.verifyError(@() simulation.markCompleted(rejected{index}), ...
                    'trnrun:InvalidCompletionEvent', sprintf('input %d', index));
            end
            testCase.verifyFalse(simulation.isFinished);
        end

        function markCompletedKeepsTheFirstCompletion(testCase)
            %MARKCOMPLETEDKEEPSTHEFIRSTCOMPLETION A duplicate completion changes nothing.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.markCompleted(completionEvent(0));
            simulation.markCompleted(completionEvent(9));

            testCase.verifyEqual(simulation.completionEvent.exitCode, 0);
        end

        % -----------------------------------------------------------------
        % Outcome
        % -----------------------------------------------------------------

        function hasTerminalStatusCoversEveryTerminalStatus(testCase)
            %HASTERMINALSTATUSCOVERSEVERYTERMINALSTATUS Terminal detection is status-driven.

            for status = trnrun.Simulation.TerminalStatuses
                simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
                simulation.applyEvent(statusEvent(status));
                testCase.verifyTrue(simulation.hasTerminalStatus, status);
            end

            running = trnrun.Simulation("a.dck", testCase.Config, 1);
            running.applyEvent(statusEvent("RUNNING"));
            testCase.verifyFalse(running.hasTerminalStatus);
        end

        function succeededRequiresCompletionAndDoneStatus(testCase)
            %SUCCEEDEDREQUIRESCOMPLETIONANDDONESTATUS Both signals must agree.

            done = trnrun.Simulation("a.dck", testCase.Config, 1);
            done.applyEvent(statusEvent("DONE"));
            done.markCompleted(completionEvent());

            errored = trnrun.Simulation("a.dck", testCase.Config, 2);
            errored.applyEvent(statusEvent("ERROR"));
            errored.markCompleted(completionEvent());

            silent = trnrun.Simulation("a.dck", testCase.Config, 3);
            silent.markCompleted(completionEvent());

            testCase.verifyTrue(done.succeeded);
            testCase.verifyFalse(errored.succeeded);
            testCase.verifyFalse(silent.succeeded);
        end

        function successIgnoresExitCode(testCase)
            %SUCCESSIGNORESEXITCODE Runner status, not the exit code, decides success.

            simulation = trnrun.Simulation("a.dck", testCase.Config, 1);
            simulation.applyEvent(statusEvent("DONE"));
            simulation.markCompleted(completionEvent(17));

            testCase.verifyTrue(simulation.succeeded);
        end

        function arraysOfSimulationsSupportBulkQueries(testCase)
            %ARRAYSOFSIMULATIONSSUPPORTBULKQUERIES The manager filters with logical masks.

            simulations = trnrun.Simulation.empty(1, 0);
            for index = 1:3
                simulations(index) = ...
                    trnrun.Simulation("a.dck", testCase.Config, index);
            end
            simulations(2).applyEvent(statusEvent("DONE"));
            simulations(2).markCompleted(completionEvent());

            testCase.verifyEqual([simulations.isFinished], [false true false]);
            testCase.verifyEqual([simulations.succeeded], [false true false]);
            testCase.verifyEqual([simulations.id], [1 2 3]);
        end
    end
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the toolbox folder next to this tests folder.

    folder = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox');
end

function setProperty(simulation, name, value)
    %SETPROPERTY Assign a property so access rules apply inside a testable call.

    simulation.(name) = value;
end

function event = statusEvent(status)
    %STATUSEVENT Build a STATUS event as parseStreamLine would emit it.

    event = struct('kind', "STATUS", 'runID', "1", 'status', string(status), ...
        'timestamp', "t", 'message', "");
end

function event = logEvent(severity, message)
    %LOGEVENT Build a LOG event as parseStreamLine would emit it.

    event = struct('kind', "LOG", 'runID', "1", 'severity', string(severity), ...
        'timestamp', "t", 'time', NaN, 'unitID', NaN, 'typeID', NaN, ...
        'messageCode', NaN, 'message', string(message), ...
        'information', string(missing));
end

function event = completionEvent(exitCode)
    %COMPLETIONEVENT Build a QUEUE/COMPLETED event, optionally with an exit code.

    if nargin < 1
        exitCode = NaN;
    end
    event = struct('kind', "QUEUE", 'event', "COMPLETED", 'runID', "1", ...
        'timestamp', "t", 'exitCode', exitCode);
end
