classdef SimulationManager < handle
    %SIMULATIONMANAGER Submit and monitor simulations through one queue process.

    properties (Dependent, SetAccess = private)
        simulations
        succeeded
        failed
        sessionDiagnostics
    end

    properties (Access = private)
        transport
        display
        sims = trnrun.Simulation.empty(1, 0)
        nextId (1,1) double = 1
        queueEof (1,1) logical = false
        shutdownStarted (1,1) logical = false
        shutdownComplete (1,1) logical = false
        busy (1,1) logical = false
        diagnostics (1,:) string = strings(1, 0)
    end

    properties (Constant, Access = private)
        MaxSessionDiagnostics = 200
    end

    methods
        function obj = SimulationManager(options)
            %SIMULATIONMANAGER Create a manager backed by one TRNRun queue process.
            %   OBJ = trnrun.SimulationManager() starts the queue with default
            %   settings. Supply name-value arguments to customize its behavior:
            %
            %   maxConcurrent - Positive integer limit on concurrent runs.
            %       Defaults to NUMBER_OF_PROCESSORS minus one, with a minimum
            %       of one; missing or invalid processor counts use one.
            %   refreshInterval - Real, finite display refresh interval in
            %       seconds (default 1). Values at or below zero disable output.
            %   trnrunqPath - Path to the queue executable. Defaults to
            %       bin/trnrunq.exe beneath the trnrun package directory.
            %
            %   Use add to submit runs, wait to process updates until completion,
            %   or follow to receive callbacks as updates are applied. Call
            %   shutdown to close queue input, drain output, and wait for exit.
            %   Deleting the manager performs best-effort cleanup instead.
            %
            %   Example:
            %       manager = trnrun.SimulationManager( ...
            %           maxConcurrent=4, refreshInterval=0.5);
            %       simulation = manager.add(deckFile, config);
            %       manager.wait(simulation);
            %       manager.shutdown();

            arguments
                options.maxConcurrent (1,1) double ...
                    {mustBeInteger, mustBePositive, mustBeFinite} = defaultConcurrency()
                options.refreshInterval (1,1) double ...
                    {mustBeReal, mustBeFinite} = 1.0
                options.trnrunqPath (1,1) string = fullfile( ...
                    fileparts(fileparts(mfilename('fullpath'))), ...
                    'bin', 'trnrunq.exe')
            end

            obj.display = trnrun.internal.Display(options.refreshInterval);
            obj.transport = trnrun.internal.QueueProcess( ...
                options.trnrunqPath, options.maxConcurrent);
        end

        function simulation = add(obj, deckFile, config)
            %ADD Submit one run and return only after QUEUE/ACCEPTED.

            arguments
                obj (1,1) trnrun.SimulationManager
                deckFile (1,1) string {mustBeFile}
                config (1,1) trnrun.SimulationConfig
            end

            guard = obj.enterOperation('add'); %#ok<NASGU>
            obj.requireOpen();
            config = config.validate();

            [found, info] = fileattrib(deckFile);
            if ~found
                error('trnrun:DeckNotFound', ...
                    'Cannot resolve deck file: %s', deckFile);
            end

            runId = obj.nextId;
            obj.nextId = obj.nextId + 1;
            simulation = trnrun.Simulation(info.Name, config, runId);

            request = struct( ...
                'runID', sprintf('%d', runId), ...
                'deckFile', info.Name, ...
                'runnerPath', char(config.trnrun_path), ...
                'runnerArgs', {config.to_cli_args()});

            obj.sims(end + 1) = simulation;
            try
                obj.transport.send(request);
            catch exception
                % A failed write may have reached the queue; never reuse its ID.
                obj.sims(end) = [];
                rethrow(exception);
            end

            while ~simulation.isAccepted
                obj.readNextUpdate();
                if simulation.isFinished && ~simulation.isAccepted
                    error('trnrun:QueueProtocolError', ...
                        'Run ID %d completed before it was accepted.', runId);
                end
            end
        end

        function wait(obj, simulation)
            %WAIT Wait for one owned simulation, or all simulations when omitted.

            arguments
                obj (1,1) trnrun.SimulationManager
                simulation trnrun.Simulation {mustBeScalarOrEmpty} = ...
                    trnrun.Simulation.empty(1, 0)
            end

            guard = obj.enterOperation('wait'); %#ok<NASGU>
            if isempty(simulation)
                pending = obj.sims(~[obj.sims.isFinished]);
            else
                if ~any(obj.sims == simulation)
                    error('trnrun:ForeignSimulation', ...
                        'Simulation does not belong to this manager.');
                end
                pending = simulation(~simulation.isFinished);
            end

            if isempty(pending)
                return
            end
            obj.requireOpen();

            while ~isempty(pending)
                obj.readNextUpdate();
                pending = pending(~[pending.isFinished]);
            end
        end

        function follow(obj, callback)
            %FOLLOW Invoke callback after every newly applied update until completion.

            arguments
                obj (1,1) trnrun.SimulationManager
                callback (1,1) function_handle
            end

            guard = obj.enterOperation('follow'); %#ok<NASGU>
            pending = obj.sims(~[obj.sims.isFinished]);
            if isempty(pending)
                return
            end
            obj.requireOpen();

            while ~isempty(pending)
                simulation = obj.readNextUpdate();
                callback(simulation);
                pending = pending(~[pending.isFinished]);
            end
        end

        function shutdown(obj)
            %SHUTDOWN Close input, drain output, and reap the queue.

            if obj.shutdownComplete
                return
            end
            guard = obj.enterOperation('shutdown'); %#ok<NASGU>
            obj.shutdownStarted = true;
            obj.transport.close();

            % Reap even when draining fails, without hiding the original error.
            failure = [];
            exitCode = [];
            try
                while ~obj.queueEof
                    obj.readNextUpdate();
                end
            catch exception
                failure = exception;
            end

            try
                exitCode = obj.transport.wait();
            catch exception
                if isempty(failure)
                    rethrow(exception);
                end
                obj.addDiagnostic("queue reap failed: " + exception.message);
            end

            if ~isempty(failure)
                throwAsCaller(failure);
            end
            if ~isempty(exitCode) && exitCode ~= 0
                error('trnrun:QueueExitFailure', ...
                    'TRNRun queue exited with code %d.%s', ...
                    exitCode, obj.transportDiagnosticSuffix());
            end
            obj.shutdownComplete = true;
        end

        function value = get.simulations(obj)
            %GET.SIMULATIONS Return simulations accepted by the queue.

            value = obj.sims([obj.sims.isAccepted]);
        end

        function value = get.succeeded(obj)
            %GET.SUCCEEDED Return accepted simulations that succeeded.

            accepted = obj.simulations;
            value = accepted([accepted.succeeded]);
        end

        function value = get.failed(obj)
            %GET.FAILED Return accepted simulations that finished without success.

            accepted = obj.simulations;
            value = accepted([accepted.isFinished] & ~[accepted.succeeded]);
        end

        function value = get.sessionDiagnostics(obj)
            %GET.SESSIONDIAGNOSTICS Return retained queue and protocol diagnostics.

            value = obj.diagnostics;
        end

        function delete(obj)
            %DELETE Clean up the queue without throwing during destruction.

            try
                if ~isempty(obj.transport) && ~obj.shutdownComplete
                    obj.transport.forceCleanup();
                end
            catch
            end
        end
    end

    methods (Access = private)
        function simulation = readNextUpdate(obj)
            %READNEXTUPDATE Apply the next valid update, or return empty at EOF.

            while true
                line = obj.transport.readLine();

                % Numeric [] is EOF; an empty character vector is a blank line.
                if isnumeric(line) && isempty(line)
                    obj.queueEof = true;
                    unfinished = obj.sims(~[obj.sims.isFinished]);
                    if ~isempty(unfinished)
                        error('trnrun:PrematureQueueEOF', ...
                            ['TRNRun queue closed before accepting or completing ' ...
                             'run IDs: %s.%s'], ...
                            strjoin(string([unfinished.id]), ', '), ...
                            obj.transportDiagnosticSuffix());
                    end
                    simulation = [];
                    return
                end

                try
                    [runId, event] = trnrun.internal.parseStreamLine(line);
                catch exception
                    if ~strcmp(exception.identifier, 'trnrun:EventParseError')
                        rethrow(exception);
                    end
                    obj.addDiagnostic("dropped malformed queue line: " + line);
                    continue
                end

                if isempty(runId)
                    obj.addDiagnostic("unroutable queue output: " + line);
                    continue
                end

                % Match wire IDs exactly: "01" and "1.0" are not run "1".
                index = find(string([obj.sims.id]) == string(runId), 1);
                if isempty(index)
                    obj.addDiagnostic("unroutable queue output: " + line);
                    continue
                end

                simulation = obj.sims(index);
                if simulation.isFinished
                    obj.addDiagnostic("update after completion: " + line);
                    continue
                end

                switch event.kind
                    case 'QUEUE'
                        switch event.event
                            case 'ACCEPTED'
                                if simulation.isAccepted
                                    obj.addDiagnostic( ...
                                        "duplicate acceptance for run ID " + runId);
                                    continue
                                end
                                simulation.markAccepted();
                                obj.display.simulationStarted(simulation);

                            case 'COMPLETED'
                                simulation.markCompleted(event);
                                obj.display.simulationFinished(simulation);

                            otherwise
                                obj.addDiagnostic("unknown queue event: " + line);
                                continue
                        end

                    otherwise
                        simulation.applyEvent(event);
                        obj.display.refresh();
                end
                return
            end
        end

        function requireOpen(obj)
            %REQUIREOPEN Reject operations after shutdown has started.

            if obj.shutdownStarted
                error('trnrun:ManagerShutdown', ...
                    'Cannot start an operation after manager shutdown has started.');
            end
        end

        function guard = enterOperation(obj, operation)
            %ENTEROPERATION Reject reentrancy and return a cleanup guard.
            %   Transport waits can invoke graphics callbacks; follow callbacks
            %   must also remain inside the same reentrancy guard.

            if obj.busy
                error('trnrun:ReentrantOperation', ...
                    'Cannot call %s while another manager operation is active.', ...
                    operation);
            end
            obj.busy = true;
            guard = onCleanup(@() obj.leaveOperation());
        end

        function leaveOperation(obj)
            %LEAVEOPERATION Clear the active-operation flag.

            obj.busy = false;
        end

        function addDiagnostic(obj, text)
            %ADDDIAGNOSTIC Append a session diagnostic and discard excess old entries.

            obj.diagnostics(end + 1) = text;
            if numel(obj.diagnostics) > obj.MaxSessionDiagnostics
                obj.diagnostics(1) = [];
            end
        end

        function suffix = transportDiagnosticSuffix(obj)
            %TRANSPORTDIAGNOSTICSUFFIX Format available queue stderr for an error.

            suffix = "";
            try
                details = obj.transport.diagnostics();
                if details.stderr_dropped > 0
                    suffix = string(sprintf( ...
                        ' (%d older stderr lines dropped)', ...
                        details.stderr_dropped));
                end
                if ~isempty(details.stderr)
                    suffix = suffix + " Queue stderr: " + ...
                        strjoin(string(details.stderr), ' | ');
                end
            catch
                % Optional diagnostics must not mask the original queue error.
            end
        end
    end
end

function value = defaultConcurrency()
    %DEFAULTCONCURRENCY Reserve one logical processor, allowing at least one run.
    %   Windows reports logical processors independently of MATLAB's thread limit.

    count = str2double(getenv('NUMBER_OF_PROCESSORS'));
    if ~isfinite(count) || count < 1
        count = 1;
    end
    value = max(fix(count) - 1, 1);
end
