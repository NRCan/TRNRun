classdef SimulationManagerTest < matlab.unittest.TestCase
    %SIMULATIONMANAGERTEST trnrun.SimulationManager and trnrun.Daemon against the real trnrund.exe.
    %   Python plays TRNRun: trnrund starts the runner as
    %   <python> <deck> <args...>, so each deck is a Python script that
    %   prints TRNRun's events and exits. A gated deck waits for its .go file.
    %
    %   Skipped without toolbox/bin/trnrund.exe or a Python interpreter
    %   (see pyenv). Displays are disabled unless a test is about them.

    properties
        Python (1,1) string = missing
        Folder (1,1) string = missing
        DeckCount (1,1) double = 0
    end

    methods (TestClassSetup)
        function findExecutables(testCase)
            %FINDEXECUTABLES Put the toolbox on the path and find trnrund and Python.

            testCase.applyFixture(matlab.unittest.fixtures.PathFixture(toolboxFolder()));
            testCase.assumeTrue(isfile(fullfile(toolboxFolder(), 'bin', 'trnrund.exe')), ...
                'toolbox/bin/trnrund.exe is missing; run nimble deploy in components/trnrund.');
            environment = pyenv();
            testCase.Python = environment.Executable;
            testCase.assumeTrue(isfile(testCase.Python), 'No Python interpreter found.');
        end
    end

    methods (TestMethodSetup)
        function createDeckFolder(testCase)
            %CREATEDECKFOLDER Give each test its own folder of decks.

            testCase.Folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            testCase.DeckCount = 0;
        end
    end

    methods (Test)
        function waitForRunningBlocksUntilStarted(testCase)
            %WAITFORRUNNINGBLOCKSUNTILSTARTED With one worker, the second deck stays queued.

            manager = testCase.makeManager();
            firstDeck = testCase.deck(gated=true);
            first = manager.add(firstDeck, waitFor="RUNNING");
            testCase.verifyEqual(first.state, "RUNNING");
            second = manager.add(testCase.deck());
            manager.refresh();
            testCase.verifyEqual(second.state, "QUEUED");

            openGate(firstDeck);
            manager.wait(second, until="RUNNING");
            manager.wait();

            testCase.verifyEqual([manager.simulations.succeeded], [true, true]);
            testCase.verifyEqual(second.logs(1).message, 'careful', ...
                'The simulation add returned is updated in place.');
        end

        function waitForFinishedPrintsEachRunOnce(testCase)
            %WAITFORFINISHEDPRINTSEACHRUNONCE Finished runs reach the Command Window once.

            before = findall(groot, 'Type', 'figure');
            testCase.addTeardown(@() closeNewFigures(before));
            manager = testCase.makeManager(workers=2, refreshInterval=3600);
            simulations = trnrun.Simulation.empty(1, 0); %#ok<NASGU>

            output = evalc(['for index = 1:3, simulations(index) = manager.add(' ...
                'testCase.deck(), label=sprintf("run%d", index), waitFor="FINISHED"); end']);

            testCase.verifyTrue(all([simulations.succeeded]));
            testCase.verifyEqual(arrayfun(@(index) count(string(output), ...
                sprintf("run%d", index)), 1:3), [1, 1, 1]);
            testCase.verifySubstring(output, 'Status: DONE');
        end

        function refreshReleasesFinishedSimulations(testCase)
            %REFRESHRELEASESFINISHEDSIMULATIONS Once collected, trnrund forgets it; the manager keeps it.

            manager = testCase.makeManager();
            simulation = manager.add(testCase.deck(), waitFor="FINISHED");

            testCase.verifyEmpty(manager.daemon.simulations("FINISHED"));
            testCase.verifyEqual(manager.simulations, simulation);
            testCase.verifyEqual(simulation.trnrunStatus, "DONE");
            testCase.verifyEqual(simulation.stopTime, 10);
        end

        function aCancelledQueuedSimulationCountsPastRunning(testCase)
            %ACANCELLEDQUEUEDSIMULATIONCOUNTSPASTRUNNING One cancelled before it starts satisfies RUNNING.

            manager = testCase.makeManager();
            manager.add(testCase.deck(gated=true), waitFor="RUNNING");
            queued = manager.add(testCase.deck());

            manager.cancel(queued);
            manager.wait(queued, until="RUNNING", timeout=10);

            testCase.verifyEqual(queued.state, "FINISHED");
            testCase.verifyEqual(queued.trnrunStatus, "CANCELLED");
            testCase.verifyTrue(isnat(queued.startedAt));
            testCase.verifyWarningFree(@() manager.cancel(queued), ...
                'A collected simulation is left unchanged.');
        end

        function waitsOnASimulationItDidNotAdd(testCase)
            %WAITSONASIMULATIONITDIDNOTADD Wait follows a daemon simulation by simId.

            manager = testCase.makeManager();
            simulation = manager.daemon.simulation(manager.daemon.add(testCase.deck()));

            manager.wait(simulation, timeout=10);

            tracked = manager.simulations([manager.simulations.simId] == simulation.simId);
            testCase.verifyTrue(tracked.succeeded);
            testCase.verifyNotSameHandle(tracked, simulation, ...
                'The manager tracks its own copy of a simulation it did not return.');
        end

        function rejectsBadStatesBeforeQueuing(testCase)
            %REJECTSBADSTATESBEFOREQUEUING A wrong waitFor or until queues nothing.

            manager = testCase.makeManager();
            deck = testCase.deck();

            testCase.verifyError(@() manager.add(deck, waitFor="DONE"), ...
                'MATLAB:validators:mustBeMember');
            testCase.verifyError(@() manager.wait(until="DONE"), ...
                'MATLAB:validators:mustBeMember');
            testCase.verifyError(@() manager.add(fullfile(testCase.Folder, 'missing.dck')), ...
                'MATLAB:validators:mustBeFile');
            testCase.verifyEmpty(manager.daemon.simulations("QUEUED"));
            testCase.verifyEmpty(manager.simulations);
        end

        function waitTimesOut(testCase)
            %WAITTIMESOUT Wait raises trnrun:Timeout while a simulation still runs.

            manager = testCase.makeManager();
            simulation = manager.add(testCase.deck(gated=true));

            testCase.verifyError(@() manager.wait(simulation, timeout=0.2), 'trnrun:Timeout');
        end

        function waitWithNothingAddedReturns(testCase)
            %WAITWITHNOTHINGADDEDRETURNS No simulation means nothing to wait for.

            manager = testCase.makeManager();

            testCase.verifyWarningFree(@() manager.wait(timeout=0));
        end

        function settingsReachTrnrund(testCase)
            %SETTINGSREACHTRNRUND The added simulation carries its TRNRun flags.

            manager = testCase.makeManager();

            simulation = manager.add(testCase.deck(), ...
                trnrun.SimulationSettings(watchTmp=true), label="tagged");

            testCase.verifyEqual(simulation.trnrunOptions, struct('watchTmp', true));
            testCase.verifyEqual(simulation.label, "tagged");
        end

        function nonAsciiTextRoundTrips(testCase)
            %NONASCIITEXTROUNDTRIPS Accented paths and labels survive trnrund's UTF-8 pipes.

            testCase.Folder = fullfile(testCase.Folder, "résultats");
            mkdir(testCase.Folder);
            manager = testCase.makeManager();
            deck = testCase.deck();

            simulation = manager.add(deck, label="bâtiment", waitFor="FINISHED");

            testCase.verifyEqual(simulation.deckFile, deck);
            testCase.verifyEqual(simulation.label, "bâtiment");
            testCase.verifyTrue(simulation.succeeded);
        end

        function aFailedRunHasNotSucceeded(testCase)
            %AFAILEDRUNHASNOTSUCCEEDED A nonzero runner exit is a failure.

            manager = testCase.makeManager();

            simulation = manager.add(testCase.deck(exitCode=1), waitFor="FINISHED");

            testCase.verifyFalse(simulation.succeeded);
            testCase.verifyEqual(simulation.exitCode, 1);
        end

        function refusedRequestsRaiseRequestError(testCase)
            %REFUSEDREQUESTSRAISEREQUESTERROR trnrund's error message reaches MATLAB.

            manager = testCase.makeManager();
            daemon = manager.daemon;

            testCase.verifyError(@() daemon.release(999), 'trnrun:RequestError');
            testCase.verifyWarningFree(@() daemon.request(struct('cmd', 'ready')), ...
                'A refused request leaves the daemon usable.');
        end

        function aDaemonThatExitsRaisesDaemonExited(testCase)
            %ADAEMONTHATEXITSRAISESDAEMONEXITED Python as trnrund rejects --trnrun and exits.

            testCase.verifyError(@() trnrun.Daemon(trnrundPath=testCase.Python, ...
                trnrunPath=testCase.Python), 'trnrun:DaemonExited');
        end

        function deletingTheManagerClosesTrnrund(testCase)
            %DELETINGTHEMANAGERCLOSESTRNRUND A running simulation is cancelled with its daemon.

            manager = testCase.makeManager();
            daemon = manager.daemon;
            manager.add(testCase.deck(gated=true), waitFor="RUNNING");

            delete(manager);

            testCase.verifyFalse(isvalid(daemon));
        end
    end

    methods (Access = private)
        function manager = makeManager(testCase, options)
            %MAKEMANAGER Start a manager polling every 10 ms, with Python as the runner.

            arguments
                testCase
                options.workers = 1
                options.refreshInterval = 0
            end

            manager = trnrun.SimulationManager(workers=options.workers, ...
                refreshInterval=options.refreshInterval, pollInterval=0.01, ...
                trnrunPath=testCase.Python);
            testCase.addTeardown(@() delete(manager));
        end

        function path = deck(testCase, options)
            %DECK Write a fake deck printing a DONE run's events; gated=true waits for its .go file.

            arguments
                testCase
                options.gated (1,1) logical = false
                options.exitCode (1,1) double = 0
            end

            testCase.DeckCount = testCase.DeckCount + 1;
            path = fullfile(testCase.Folder, sprintf('deck%d.dck', testCase.DeckCount));
            gated = 'False';
            if options.gated
                gated = 'True';
            end
            events = strjoin({ ...
                '{"kind":"STATUS","status":"RUNNING","message":""}', ...
                '{"kind":"CONFIG","start":0,"stop":10,"step":1}', ...
                '{"kind":"LOG","severity":"Warning","time":5,"unitId":7,"typeId":56,"message":"careful"}', ...
                '{"kind":"PROGRESS","time":10,"percent":1,"elapsedMs":5,"etaMs":0}', ...
                '{"kind":"STATUS","status":"DONE","message":""}'}, newline);
            fid = fopen(path, 'w');
            fprintf(fid, ['import sys, time\n' ...
                'from pathlib import Path\n' ...
                'gate = Path(sys.argv[0]).with_suffix(".go")\n' ...
                'deadline = time.monotonic() + 30\n' ...
                'while %s and not gate.exists() and time.monotonic() < deadline:\n' ...
                '    time.sleep(0.01)\n' ...
                'print(r''''''%s'''''', flush=True)\n' ...
                'sys.exit(%d)\n'], gated, events, options.exitCode);
            fclose(fid);
        end
    end
end

function folder = toolboxFolder()
    %TOOLBOXFOLDER Return the toolbox folder next to this tests folder.

    folder = fullfile(fileparts(fileparts(mfilename('fullpath'))), 'toolbox');
end

function openGate(deck)
    %OPENGATE Let a gated deck print its events.

    [folder, name] = fileparts(deck);
    fclose(fopen(fullfile(folder, name + ".go"), 'w'));
end

function closeNewFigures(before)
    %CLOSENEWFIGURES Delete figures created since BEFORE was captured.

    created = setdiff(findall(groot, 'Type', 'figure'), before);
    delete(created(isgraphics(created)));
end
