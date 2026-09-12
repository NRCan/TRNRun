classdef Simulation < handle
    %SIMULATION Track event state for one queued simulation.
    %   The manager folds queue output into this object as it pumps the
    %   queue; handle semantics let callers observe updates live.
    %
    %   Queue completion and runner outcome are tracked separately: a run
    %   succeeded only if the queue reported COMPLETED *and* the runner's
    %   latest status is DONE.

    properties (Constant)
        TerminalStatuses (1,:) string = ["DONE" "ERROR" "CANCELLED" "TIMEOUT" "STALLED"]
    end

    properties (SetAccess = immutable)
        id (1,1) double
        deckPath (1,1) string
        config (1,1) trnrun.SimulationConfig
    end

    properties (SetAccess = private)
        isAccepted (1,1) logical = false
        completionEvent struct {mustBeScalarOrEmpty} = struct([]) % QUEUE/COMPLETED
        status struct {mustBeScalarOrEmpty} = struct([])          % latest STATUS
        progress struct {mustBeScalarOrEmpty} = struct([])        % latest PROGRESS
        configEvent struct {mustBeScalarOrEmpty} = struct([])     % latest CONFIG
        settingEvent struct {mustBeScalarOrEmpty} = struct([])    % latest SETTING
        logs struct = struct([])                                 % all LOG events, oldest first

        % Running totals maintained as logs arrive, so repeated reads during
        % display refreshes do not rescan the whole log history.
        logCount (1,1) double = 0        % total LOG events received
        notices (1,1) double = 0         % severity totals; unknown severities
        warnings (1,1) double = 0        % contribute to logCount only
        fatals (1,1) double = 0
    end

    properties (Dependent, SetAccess = private)
        state                            % 'pending', 'running' or 'finished'
        isRunning (1,1) logical          % true until finished (includes pending)
        isFinished (1,1) logical
        hasTerminalStatus (1,1) logical
        succeeded (1,1) logical
    end

    methods
        function obj = Simulation(deckPath, config, simId)
            %SIMULATION Create event state for one queued simulation.
            %   OBJ = trnrun.Simulation(DECKPATH, CONFIG, SIMID) creates a
            %   handle object with no recorded events. DECKPATH is the deck
            %   path, CONFIG is a trnrun.SimulationConfig value, and SIMID is
            %   the numeric queue identifier. The run remains unfinished until
            %   markCompleted is called.

            % Report the offending argument directly; property validation
            % alone would blame the property rather than the input.
            if ~isa(config, 'trnrun.SimulationConfig') || ~isscalar(config)
                error('trnrun:InvalidConfig', ...
                    'CONFIG must be a scalar trnrun.SimulationConfig.');
            end
            if ~isnumeric(simId) || ~isscalar(simId) || ~isreal(simId) || ...
                    ~isfinite(simId) || simId < 1 || mod(simId, 1) ~= 0
                error('trnrun:InvalidInteger', ...
                    'SIMID must be a positive integer-valued numeric scalar.');
            end

            obj.id = simId;
            obj.deckPath = deckPath;
            obj.config = config;
        end

        function applyEvent(obj, event)
            %APPLYEVENT Record a recognized runner event unless the run is finished.

            if obj.isFinished
                return
            end

            switch event.kind
                case "STATUS"
                    obj.status = event;
                case "PROGRESS"
                    obj.progress = event;
                case "CONFIG"
                    obj.configEvent = event;
                case "SETTING"
                    obj.settingEvent = event;
                case "LOG"
                    obj.logs = [obj.logs, event];
                    obj.logCount = obj.logCount + 1;
                    obj.tallySeverity(event);
            end
        end

        function value = logTable(obj)
            %LOGTABLE Return retained log events as a table, oldest first.
            %   Fields and values are unchanged. With no retained logs the
            %   result is table(), because no log schema is available yet.

            if isempty(obj.logs)
                value = table();
            else
                value = struct2table(obj.logs, 'AsArray', true);
            end
        end

        function markAccepted(obj)
            %MARKACCEPTED Record that a queue worker accepted the run.

            obj.isAccepted = true;
        end

        function markCompleted(obj, event)
            %MARKCOMPLETED Retain the QUEUE/COMPLETED event and finish the run.
            %   A rejected event leaves the simulation unchanged. exitCode is
            %   optional, so a completion without one still finishes the run.

            if ~isstruct(event) || ~isscalar(event) || ...
                    ~isfield(event, 'kind') || ~isfield(event, 'event') || ...
                    ~isequal(string(event.kind), "QUEUE") || ...
                    ~isequal(string(event.event), "COMPLETED")
                error('trnrun:InvalidCompletionEvent', ...
                    'EVENT must be a scalar QUEUE/COMPLETED event struct.');
            end

            if ~obj.isFinished
                obj.completionEvent = event;
            end
        end

        function value = get.state(obj)
            %GET.STATE Return lifecycle stage as a character vector.
            %   Queue completion wins over acceptance, so a run completed
            %   without acceptance still reports 'finished'. Runner status
            %   does not affect the stage.

            if obj.isFinished
                value = 'finished';
            elseif obj.isAccepted
                value = 'running';
            else
                value = 'pending';
            end
        end

        function value = get.isRunning(obj)
            %GET.ISRUNNING Return true until queue completion, including pending runs.

            value = ~obj.isFinished;
        end

        function value = get.isFinished(obj)
            %GET.ISFINISHED Return true when a queue completion event is recorded.

            value = ~isempty(obj.completionEvent);
        end

        function value = get.hasTerminalStatus(obj)
            %GET.HASTERMINALSTATUS Return true when the latest runner status is terminal.

            value = ~isempty(obj.status) && ...
                ismember(string(obj.status.status), obj.TerminalStatuses);
        end

        function value = get.succeeded(obj)
            %GET.SUCCEEDED Return true after queue completion with runner status DONE.

            value = obj.isFinished && ~isempty(obj.status) && ...
                string(obj.status.status) == "DONE";
        end

    end

    methods (Access = private)
        function tallySeverity(obj, event)
            %TALLYSEVERITY Add one log event to its severity total, ignoring case.
            %   Absent, empty and unrecognized severities are counted by
            %   logCount alone.

            if ~isfield(event, 'severity')
                return
            end
            severity = string(event.severity);
            if ~isscalar(severity) || ismissing(severity)
                return
            end

            switch lower(severity)
                case "notice"
                    obj.notices = obj.notices + 1;
                case "warning"
                    obj.warnings = obj.warnings + 1;
                case "fatal"
                    obj.fatals = obj.fatals + 1;
            end
        end
    end
end
