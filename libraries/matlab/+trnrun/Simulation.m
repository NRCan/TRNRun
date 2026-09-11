classdef Simulation < handle
    %SIMULATION Event state for one queued simulation.
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
    end

    properties (Dependent, SetAccess = private)
        isRunning (1,1) logical          % true until finished (includes pending)
        isFinished (1,1) logical
        hasTerminalStatus (1,1) logical
        succeeded (1,1) logical
        logCount (1,1) double
        notices (1,1) double
        warnings (1,1) double
        fatals (1,1) double
    end

    methods
        function obj = Simulation(deckPath, config, simId)
            %SIMULATION Create event state for one queued simulation.
            %   OBJ = trnrun.Simulation(DECKPATH, CONFIG, SIMID) creates a
            %   handle object that retains runner events and queue state.
            %
            %   Inputs:
            %     DECKPATH - Scalar string containing the simulation deck path.
            %     CONFIG  - Scalar trnrun.SimulationConfig for the run.
            %     SIMID   - Scalar double identifying the queued simulation.
            %
            %   Output:
            %     OBJ - Simulation handle with no recorded events. The run
            %           remains unfinished until markCompleted is called.
            %
            %   Queue completion and runner status are tracked separately.
            %   A run succeeds only after queue completion with a latest
            %   runner status of DONE.

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
            end
        end

        function markAccepted(obj)
            %MARKACCEPTED Record that a queue worker accepted the run.

            obj.isAccepted = true;
        end

        function markCompleted(obj, event)
            %MARKCOMPLETED Retain the QUEUE/COMPLETED event and finish the run.

            if ~obj.isFinished
                obj.completionEvent = event;
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

        function value = get.logCount(obj)
            %GET.LOGCOUNT Return the total number of recorded log events.
            value = numel(obj.logs);
        end

        function value = get.notices(obj)
            %GET.NOTICES Return the number of notice log events.
            value = obj.countSeverity("notice");
        end

        function value = get.warnings(obj)
            %GET.WARNINGS Return the number of warning log events.
            value = obj.countSeverity("warning");
        end

        function value = get.fatals(obj)
            %GET.FATALS Return the number of fatal log events.
            value = obj.countSeverity("fatal");
        end
    end

    methods (Access = private)
        function n = countSeverity(obj, severity)
            %COUNTSEVERITY Count log events matching severity, ignoring case.

            if isempty(obj.logs)
                n = 0;
            else
                n = sum(strcmpi(string({obj.logs.severity}), severity));
            end
        end
    end
end
