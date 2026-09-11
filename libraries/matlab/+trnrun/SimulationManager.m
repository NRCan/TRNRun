classdef SimulationManager < handle
    %SIMULATIONMANAGER Submit and monitor simulations through one queue process.

    properties (Dependent, SetAccess = private)
        simulations
        succeeded
        failed
        session_diagnostics
    end

    properties (Access = private)
        transport_
        display_
        accepted_ = {}
        owned_ = {}
        active_
        next_id_ = 1
        queue_eof_ = false
        shutdown_started_ = false
        shutdown_complete_ = false
        busy_ = false
        in_callback_ = false
        diagnostics_ = {}
    end

    properties (Constant, Access = private)
        MaxSessionDiagnostics = 200
    end

    methods
        function obj = SimulationManager(varargin)
            options = struct( ...
                'max_concurrent', default_concurrency(), ...
                'refresh_interval', 1.0, ...
                'trnrunq_path', fullfile(trnrun.internal.libraryRoot(), ...
                    'bin', 'win64', 'trnrunq.exe'), ...
                'transport', []);

            if mod(numel(varargin), 2) ~= 0
                error('trnrun:InvalidNameValue', ...
                    'SimulationManager options must be supplied as name-value pairs.');
            end
            names = fieldnames(options);
            for index = 1:2:numel(varargin)
                name = varargin{index};
                if isstring(name) && isscalar(name) && ~ismissing(name)
                    name = char(name);
                end
                if ~ischar(name) || ~isrow(name) || ~ismember(name, names)
                    error('trnrun:UnknownOption', ...
                        'Unknown SimulationManager option: %s', char(string(name)));
                end
                options.(name) = varargin{index + 1};
            end

            options.max_concurrent = trnrun.internal.requireFiniteInteger( ...
                options.max_concurrent, 'max_concurrent', 1);
            options.refresh_interval = trnrun.internal.requireFiniteScalar( ...
                options.refresh_interval, 'refresh_interval');

            obj.active_ = containers.Map('KeyType', 'char', 'ValueType', 'any');
            obj.display_ = trnrun.internal.Display(options.refresh_interval);
            if isempty(options.transport)
                obj.transport_ = trnrun.internal.QueueProcess( ...
                    options.trnrunq_path, options.max_concurrent);
            else
                obj.transport_ = options.transport;
            end
        end

        function simulation = add(obj, deck_file, config)
            %ADD Submit one run and return only after QUEUE/ACCEPTED.
            obj.require_submission_open();
            guard = obj.enter_operation('add'); %#ok<NASGU>

            if ~isa(config, 'trnrun.SimulationConfig') || ~isscalar(config)
                error('trnrun:InvalidConfig', ...
                    'config must be a scalar trnrun.SimulationConfig value.');
            end
            deck_path = trnrun.internal.absolutePath(deck_file, 'deck_file');
            if ~isfile(deck_path)
                error('trnrun:DeckNotFound', 'Deck file not found: %s', deck_path);
            end
            config = config.validate();

            sim_id = obj.next_id_;
            obj.next_id_ = obj.next_id_ + 1;
            run_id = sprintf('%.0f', sim_id);
            if isKey(obj.active_, run_id)
                error('trnrun:DuplicateRunId', ...
                    'Duplicate run ID in this queue session: %s', run_id);
            end

            simulation = trnrun.Simulation(deck_path, config, sim_id);
            obj.active_(run_id) = simulation;
            obj.owned_{end + 1} = simulation;

            request = struct( ...
                'runID', run_id, ...
                'deckFile', deck_path, ...
                'runnerPath', char(config.trnrun_path), ...
                'runnerArgs', {config.to_cli_args()});
            try
                obj.transport_.send(request);
            catch exception
                if isKey(obj.active_, run_id)
                    remove(obj.active_, run_id);
                end
                obj.owned_(cellfun(@(item) item == simulation, obj.owned_)) = [];
                rethrow(exception);
            end

            while ~simulation.isAccepted
                obj.read_next_update();
                if simulation.isFinished && ~simulation.isAccepted
                    error('trnrun:QueueProtocolError', ...
                        'Run ID %s completed before it was accepted.', run_id);
                end
            end
        end

        function wait(obj, simulation)
            %WAIT Wait for one owned simulation, or all simulations when omitted.
            if nargin >= 2
                obj.require_owned(simulation);
                if simulation.isFinished
                    return
                end
            else
                simulation = [];
            end

            obj.require_pump_available();
            guard = obj.enter_operation('wait'); %#ok<NASGU>
            while obj.active_.Count > 0
                obj.read_next_update();
                if ~isempty(simulation) && simulation.isFinished
                    return
                end
            end
        end

        function follow(obj, callback)
            %FOLLOW Invoke callback after every newly applied update until completion.
            if ~isa(callback, 'function_handle') || ~isscalar(callback)
                error('trnrun:InvalidCallback', ...
                    'follow requires a scalar function handle callback.');
            end
            obj.require_pump_available();
            guard = obj.enter_operation('follow'); %#ok<NASGU>

            while obj.active_.Count > 0
                simulation = obj.read_next_update();
                if isempty(simulation)
                    return
                end
                obj.in_callback_ = true;
                callback_guard = onCleanup(@() obj.leave_callback()); %#ok<NASGU>
                callback(simulation);
                clear callback_guard
            end
        end

        function shutdown(obj)
            %SHUTDOWN Close input, drain output, reap the queue; idempotent on success.
            if obj.shutdown_complete_
                return
            end
            if obj.in_callback_
                error('trnrun:ReentrantOperation', ...
                    'Manager operations are not allowed from a follow callback.');
            end
            guard = obj.enter_operation('shutdown'); %#ok<NASGU>
            obj.shutdown_started_ = true;
            obj.transport_.close();

            failure = [];
            exit_code = [];
            try
                while ~obj.queue_eof_
                    obj.read_next_update();
                end
            catch exception
                failure = exception;
            end

            try
                exit_code = obj.transport_.wait();
            catch exception
                if isempty(failure)
                    failure = exception;
                else
                    obj.add_diagnostic(['queue reap failed: ' exception.message]);
                end
            end

            if isempty(failure) && ~isempty(exit_code) && exit_code ~= 0
                failure = MException('trnrun:QueueExitFailure', ...
                    'TRNRun queue exited with code %d.%s', ...
                    exit_code, obj.transport_diagnostic_suffix());
            end

            if ~isempty(failure)
                throwAsCaller(failure);
            end
            obj.shutdown_complete_ = true;
        end

        function value = get.simulations(obj)
            value = simulation_array(obj.accepted_);
        end

        function value = get.succeeded(obj)
            selected = obj.accepted_(cellfun(@(simulation) simulation.succeeded, obj.accepted_));
            value = simulation_array(selected);
        end

        function value = get.failed(obj)
            selected = obj.accepted_(cellfun( ...
                @(simulation) simulation.isFinished && ~simulation.succeeded, ...
                obj.accepted_));
            value = simulation_array(selected);
        end

        function value = get.session_diagnostics(obj)
            value = obj.diagnostics_;
        end

        function delete(obj)
            %DELETE Non-throwing cleanup; unfinished owned work may be terminated.
            try
                if ~isempty(obj.transport_) && ~obj.shutdown_complete_
                    obj.transport_.force_cleanup();
                end
            catch
            end
        end
    end

    methods (Access = private)
        function simulation = read_next_update(obj)
            % Read until one routable state update or stdout EOF.
            while true
                line = obj.transport_.read_line();
                if isnumeric(line) && isempty(line)
                    obj.queue_eof_ = true;
                    if obj.active_.Count > 0
                        ids = obj.active_.keys;
                        error('trnrun:PrematureQueueEOF', ...
                            ['TRNRun queue closed before accepting or completing ' ...
                             'run IDs: %s.%s'], ...
                            strjoin(ids, ', '), obj.transport_diagnostic_suffix());
                    end
                    simulation = [];
                    return
                end

                try
                    [run_id, event] = trnrun.internal.parseStreamLine(line);
                catch exception
                    if strcmp(exception.identifier, 'trnrun:EventParseError')
                        obj.add_diagnostic(['dropped malformed queue line: ' char(line)]);
                        continue
                    end
                    rethrow(exception)
                end

                if isempty(run_id)
                    obj.add_diagnostic(['unroutable queue output: ' char(line)]);
                    continue
                end
                if ~isKey(obj.active_, run_id)
                    obj.add_diagnostic(['unknown run ID ' run_id ': ' char(line)]);
                    continue
                end

                simulation = obj.active_(run_id);
                if strcmp(event.kind, 'QUEUE')
                    if strcmp(event.event, 'ACCEPTED')
                        if simulation.isAccepted
                            obj.add_diagnostic(['duplicate acceptance for run ID ' run_id]);
                            continue
                        end
                        simulation.markAccepted();
                        obj.accepted_{end + 1} = simulation;
                        obj.display_.simulation_started(simulation);
                    elseif strcmp(event.event, 'COMPLETED')
                        remove(obj.active_, run_id);
                        simulation.markCompleted(event);
                        obj.display_.simulation_finished(simulation);
                    else
                        obj.add_diagnostic(['unknown queue event for run ID ' run_id ': ' event.event]);
                        continue
                    end
                else
                    simulation.applyEvent(event);
                    obj.display_.refresh();
                end
                return
            end
        end

        function require_submission_open(obj)
            if obj.shutdown_started_ || obj.shutdown_complete_
                error('trnrun:ManagerShutdown', ...
                    'Cannot submit simulations after manager shutdown has started.');
            end
            obj.require_pump_available();
        end

        function require_pump_available(obj)
            if obj.shutdown_started_ && ~obj.shutdown_complete_
                error('trnrun:ManagerShutdown', ...
                    'The manager is shutting down and cannot start another operation.');
            end
            if obj.shutdown_complete_ && obj.active_.Count > 0
                error('trnrun:ManagerShutdown', ...
                    'The manager is closed with unfinished simulations.');
            end
        end

        function require_owned(obj, simulation)
            if ~isa(simulation, 'trnrun.Simulation') || ~isscalar(simulation) || ...
                    ~any(cellfun(@(item) item == simulation, obj.owned_))
                error('trnrun:ForeignSimulation', ...
                    'Simulation does not belong to this manager.');
            end
        end

        function guard = enter_operation(obj, operation)
            if obj.busy_ || obj.in_callback_
                error('trnrun:ReentrantOperation', ...
                    'Cannot call %s while another manager operation or callback is active.', ...
                    operation);
            end
            obj.busy_ = true;
            guard = onCleanup(@() obj.leave_operation());
        end

        function leave_operation(obj)
            obj.busy_ = false;
        end

        function leave_callback(obj)
            obj.in_callback_ = false;
        end

        function add_diagnostic(obj, text)
            obj.diagnostics_{end + 1} = text;
            if numel(obj.diagnostics_) > obj.MaxSessionDiagnostics
                obj.diagnostics_(1) = [];
            end
        end

        function suffix = transport_diagnostic_suffix(obj)
            suffix = '';
            try
                details = obj.transport_.diagnostics();
                parts = {};
                if ~isempty(details.pid)
                    parts{end + 1} = sprintf('queue PID %d', details.pid); %#ok<AGROW>
                end
                if ~isempty(details.exit_code)
                    parts{end + 1} = sprintf('exit code %d', details.exit_code); %#ok<AGROW>
                end
                if details.stderr_dropped > 0
                    parts{end + 1} = sprintf('%d older stderr lines dropped', ...
                        details.stderr_dropped); %#ok<AGROW>
                end
                if ~isempty(details.stderr)
                    parts{end + 1} = ['stderr: ' strjoin(details.stderr, ' | ')]; %#ok<AGROW>
                end
                if ~isempty(parts)
                    suffix = [' Diagnostics: ' strjoin(parts, '; ')];
                end
            catch
            end
        end
    end
end

function value = simulation_array(items)
if isempty(items)
    value = trnrun.Simulation.empty(1, 0);
else
    value = [items{:}];
end
end

function value = default_concurrency()
count = 1;
try
    count = feature('numcores');
catch
    environment_count = str2double(getenv('NUMBER_OF_PROCESSORS'));
    if isfinite(environment_count) && environment_count >= 1
        count = environment_count;
    end
end
value = max(fix(double(count)) - 1, 1);
end
