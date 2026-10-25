classdef SimulationManager < handle
    %SIMULATIONMANAGER Run many simulations on one trnrund and follow them.
    %   REFRESH updates every simulation in place, so the one ADD returned
    %   stays current; its logs are filled in once it finishes.
    %
    %   Nothing runs in the background: ADD with waitFor and WAIT refresh
    %   every pollInterval seconds while they block. Call REFRESH otherwise.
    %
    %   Running simulations show in a progress window; finished ones print
    %   once to the Command Window. Deleting the manager cancels unfinished runs.
    %
    %   Example:
    %       manager = trnrun.SimulationManager(workers=4);
    %       simulation = manager.add("model.dck", trnrun.SimulationSettings(watchTmp=true));
    %       manager.wait();
    %       simulation.succeeded

    properties (SetAccess = private)
        daemon = []                                  % the trnrun.Daemon this manager owns
        simulations = trnrun.Simulation.empty(1, 0)  % every simulation seen, oldest first
    end

    properties
        pollInterval (1,1) double {mustBeNonnegative, mustBeFinite} = 0.1 % seconds between refreshes while blocking
    end

    properties (Access = private)
        display = []
    end

    properties (Constant, Access = private)
        States = ["QUEUED", "RUNNING", "FINISHED"]
    end

    methods
        function obj = SimulationManager(options)
            %SIMULATIONMANAGER Start trnrund.
            %   workers                 - Simulations run at once (default: CPU count - 1).
            %   refreshInterval         - Seconds between redraws (default 1); <= 0 disables output.
            %   pollInterval            - Seconds between refreshes while blocking (default 0.1).
            %   trnrundPath, trnrunPath - Executables, as for trnrun.Daemon.

            arguments
                options.workers (1,1) double {mustBeInteger, mustBePositive}
                options.refreshInterval (1,1) double {mustBeReal, mustBeFinite} = 1
                options.pollInterval (1,1) double {mustBeNonnegative, mustBeFinite} = 0.1
                options.trnrundPath (1,1) string
                options.trnrunPath (1,1) string
            end

            obj.pollInterval = options.pollInterval;
            daemonOptions = rmfield(options, {'refreshInterval', 'pollInterval'});
            daemonArgs = namedargs2cell(daemonOptions);
            obj.daemon = trnrun.Daemon(daemonArgs{:});
            obj.display = trnrun.internal.Display(options.refreshInterval);
        end

        function simulation = add(obj, deckFile, settings, options)
            %ADD Queue a deck and return its simulation; waitFor blocks until "RUNNING" or "FINISHED".

            arguments
                obj (1,1) trnrun.SimulationManager
                deckFile (1,1) string
                settings (1,1) trnrun.SimulationSettings = trnrun.SimulationSettings()
                options.label (1,1) string = missing
                options.waitFor (1,1) string ...
                    {mustBeMember(options.waitFor, ["QUEUED", "RUNNING", "FINISHED"])} = "QUEUED"
            end

            simId = obj.daemon.add(deckFile, settings, label=options.label);
            simulation = obj.daemon.simulation(simId);
            obj.simulations(end + 1) = simulation;
            if options.waitFor ~= "QUEUED"
                obj.wait(simulation, until=options.waitFor);
            end
        end

        function cancel(obj, simulations)
            %CANCEL Stop queued or running simulations; the next refresh shows them CANCELLED.

            arguments
                obj (1,1) trnrun.SimulationManager
                simulations trnrun.Simulation
            end

            for simulation = obj.tracked(simulations)
                % A collected one is released, so trnrund no longer knows its simId.
                if simulation.state ~= "FINISHED"
                    obj.daemon.cancel(simulation.simId);
                end
            end
        end

        function refresh(obj)
            %REFRESH Update every simulation once, collect finished ones, and redraw.

            running = obj.daemon.simulations("RUNNING");
            finished = obj.daemon.simulations("FINISHED", withLogs=true);
            % One that finished between the two requests is in both.
            running = running(~ismember([running.simId], [finished.simId]));
            for latest = [running, finished]
                simulation = obj.tracked(latest);
                if simulation == latest
                    obj.simulations(end + 1) = latest;
                else
                    simulation.update(latest);
                end
                obj.display.simulationStarted(simulation);
                if simulation.state == "FINISHED"
                    obj.daemon.release(simulation.simId);
                    obj.display.simulationFinished(simulation);
                end
            end
            obj.display.refresh();
        end

        function wait(obj, simulations, options)
            %WAIT Block until SIMULATIONS (default all) reach until (default "FINISHED"); raises trnrun:Timeout.

            arguments
                obj (1,1) trnrun.SimulationManager
                simulations trnrun.Simulation = obj.simulations
                options.until (1,1) string ...
                    {mustBeMember(options.until, ["QUEUED", "RUNNING", "FINISHED"])} = "FINISHED"
                options.timeout (1,1) double {mustBeNonnegative} = Inf
            end

            target = find(obj.States == options.until);
            started = tic;
            while true
                obj.refresh();
                current = obj.tracked(simulations);
                [~, reached] = ismember([current.state], obj.States);
                if all(reached >= target)
                    return
                end
                if toc(started) >= options.timeout
                    error('trnrun:Timeout', 'Simulations not %s after %g s.', ...
                        options.until, options.timeout);
                end
                pause(obj.pollInterval);
            end
        end

        function delete(obj)
            %DELETE Close trnrund, cancelling unfinished runs, and the progress window.

            % Empty only when construction failed.
            if ~isempty(obj.daemon)
                delete(obj.daemon);
            end
            if ~isempty(obj.display)
                delete(obj.display);
            end
        end
    end

    methods (Access = private)
        function simulations = tracked(obj, simulations)
            %TRACKED Swap each simulation for the one this manager keeps, matched by simId.

            simulations = reshape(simulations, 1, []);
            [found, index] = ismember([simulations.simId], [obj.simulations.simId]);
            simulations(found) = obj.simulations(index(found));
        end
    end
end
