classdef QueueProcess < handle
    %QUEUEPROCESS Own one trnrunq process and its redirected UTF-8 streams.

    properties (Access = private)
        process_ = []
        stdin_ = []
        stdout_ = []
        stderr_ = []
        stdout_task_ = []
        stderr_task_ = []
        job_ = []
        input_closed_ = false
        stdout_eof_ = false
        stderr_eof_ = false
        disposed_ = false
        pending_stdout_ = {}
        pending_stdout_head_ = 1
        stderr_tail_ = {}
        stderr_chars_ = 0
        stderr_dropped_ = 0
        transport_error_ = []
    end

    properties (Constant, Access = private)
        MaxStderrLines = 200
        MaxStderrChars = 65536
        PollSeconds = 0.01
    end

    methods
        function obj = QueueProcess(executable, max_concurrent)
            if ~ispc
                error('trnrun:UnsupportedPlatform', ...
                    'The MATLAB client supports Windows only.');
            end

            executable = trnrun.internal.absolutePath(executable, 'trnrunq_path');
            max_concurrent = trnrun.internal.requireFiniteInteger( ...
                max_concurrent, 'max_concurrent', 1);
            if ~isfile(executable)
                error('trnrun:QueueNotFound', ...
                    'TRNRun queue executable not found: %s', executable);
            end

            assembly_path = fullfile(trnrun.internal.libraryRoot(), ...
                'bin', 'win64', 'TrnRun.Interop.dll');
            if ~isfile(assembly_path)
                error('trnrun:JobProtectionUnavailable', ...
                    ['Windows Job Object helper not found: %s. Build or install ' ...
                     'the complete MATLAB package before starting simulations.'], ...
                    assembly_path);
            end

            try
                NET.addAssembly(assembly_path);
                obj.job_ = TrnRun.Interop.KillOnCloseJob();
            catch exception
                wrapped = MException('trnrun:JobProtectionUnavailable', ...
                    'Could not initialize Windows Job Object protection: %s', ...
                    exception.message);
                throwAsCaller(wrapped);
            end

            psi = System.Diagnostics.ProcessStartInfo();
            psi.FileName = executable;
            psi.Arguments = sprintf('--maxConcurrent:%d', max_concurrent);
            psi.WorkingDirectory = fileparts(executable);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            utf8 = System.Text.UTF8Encoding(false, false);
            psi.StandardOutputEncoding = utf8;
            psi.StandardErrorEncoding = utf8;
            psi.StandardInputEncoding = System.Text.UTF8Encoding(false, true);

            process = System.Diagnostics.Process();
            process.StartInfo = psi;
            try
                if ~process.Start()
                    error('trnrun:QueueStartFailed', ...
                        'System.Diagnostics.Process.Start returned false.');
                end
                obj.process_ = process;
                obj.job_.Assign(process);
                obj.stdin_ = process.StandardInput;
                obj.stdout_ = process.StandardOutput;
                obj.stderr_ = process.StandardError;
                obj.stdin_.AutoFlush = true;
                obj.stdout_task_ = obj.stdout_.ReadLineAsync();
                obj.stderr_task_ = obj.stderr_.ReadLineAsync();
            catch exception
                obj.process_ = process;
                obj.force_cleanup();
                wrapped = MException('trnrun:QueueStartFailed', ...
                    'Could not start and protect the TRNRun queue: %s', ...
                    exception.message);
                throwAsCaller(wrapped);
            end
        end

        function send(obj, request)
            %SEND Validate, encode, write, and flush one strict JSON request.
            obj.require_open_input();
            validate_request(request);
            reject_nonfinite(request, 'request');
            try
                line = jsonencode(request);
            catch exception
                wrapped = MException('trnrun:RequestEncodingFailed', ...
                    'Could not encode queue request: %s', exception.message);
                throwAsCaller(wrapped);
            end

            try
                write_task = obj.stdin_.WriteLineAsync(line);
                while ~write_task.IsCompleted
                    obj.pump_tasks();
                    obj.throw_transport_error();
                    pause(obj.PollSeconds);
                end
                check_task(write_task, 'queue stdin write');
                obj.stdin_.Flush();
                write_task.Dispose();
            catch exception
                wrapped = MException('trnrun:QueueWriteFailed', ...
                    'Could not write a request to the TRNRun queue: %s', ...
                    exception.message);
                throwAsCaller(wrapped);
            end
        end

        function line = read_line(obj)
            %READ_LINE Block while fairly draining both output streams.
            while true
                if obj.pending_stdout_head_ <= numel(obj.pending_stdout_)
                    line = obj.pending_stdout_{obj.pending_stdout_head_};
                    obj.pending_stdout_head_ = obj.pending_stdout_head_ + 1;
                    if obj.pending_stdout_head_ > 256 && ...
                            obj.pending_stdout_head_ > numel(obj.pending_stdout_) / 2
                        obj.pending_stdout_ = obj.pending_stdout_(obj.pending_stdout_head_:end);
                        obj.pending_stdout_head_ = 1;
                    end
                    return
                end

                obj.pump_tasks();
                obj.throw_transport_error();
                if obj.stdout_eof_
                    line = [];
                    return
                end
                pause(obj.PollSeconds);
            end
        end

        function close(obj)
            %CLOSE Close queue stdin once, ending submission without cancellation.
            if obj.disposed_ || obj.input_closed_
                return
            end
            obj.input_closed_ = true;
            try
                obj.stdin_.Close();
            catch
                % Closing an already-broken input pipe is harmless here.
            end
        end

        function exit_code = wait(obj)
            %WAIT Drain both streams, reap the queue, and release handles.
            if obj.disposed_
                exit_code = [];
                return
            end
            obj.close();

            while ~(obj.stdout_eof_ && obj.stderr_eof_)
                obj.pump_tasks();
                obj.throw_transport_error();
                pause(obj.PollSeconds);
            end

            obj.process_.WaitForExit();
            exit_code = double(obj.process_.ExitCode);
            obj.dispose_handles(false);
        end

        function value = diagnostics(obj)
            %DIAGNOSTICS Return bounded transport diagnostics by value.
            pid = [];
            exit_code = [];
            if ~isempty(obj.process_)
                try
                    pid = double(obj.process_.Id);
                    if obj.process_.HasExited
                        exit_code = double(obj.process_.ExitCode);
                    end
                catch
                end
            end
            value = struct( ...
                'pid', pid, ...
                'exit_code', exit_code, ...
                'stderr', {obj.stderr_tail_}, ...
                'stderr_dropped', obj.stderr_dropped_);
        end

        function force_cleanup(obj)
            %FORCE_CLEANUP Terminate only this transport's queue and descendants.
            if obj.disposed_
                return
            end
            obj.close();
            try
                if ~isempty(obj.job_)
                    obj.job_.Terminate(uint32(1));
                end
            catch
                try
                    if ~isempty(obj.process_) && ~obj.process_.HasExited
                        obj.process_.Kill();
                    end
                catch
                end
            end
            try
                if ~isempty(obj.process_)
                    obj.process_.WaitForExit(2000);
                end
            catch
            end
            obj.dispose_handles(true);
        end

        function delete(obj)
            try
                obj.force_cleanup();
            catch
                % MATLAB destructors must not replace an active user exception.
            end
        end
    end

    methods (Access = private)
        function require_open_input(obj)
            if obj.disposed_ || obj.input_closed_
                error('trnrun:QueueInputClosed', ...
                    'The TRNRun queue is no longer accepting submissions.');
            end
        end

        function pump_tasks(obj)
            % Always service stdout and stderr once per pass to prevent starvation.
            if ~obj.stdout_eof_ && ~isempty(obj.stdout_task_) && obj.stdout_task_.IsCompleted
                task = obj.stdout_task_;
                try
                    check_task(task, 'queue stdout read');
                    value = task.Result;
                    if is_dotnet_null(value)
                        obj.stdout_eof_ = true;
                        obj.stdout_task_ = [];
                    else
                        line = char(value);
                        obj.stdout_task_ = obj.stdout_.ReadLineAsync();
                        obj.pending_stdout_{end + 1} = line;
                    end
                    task.Dispose();
                catch exception
                    obj.transport_error_ = MException('trnrun:QueueReadFailed', ...
                        'Queue stdout read failed: %s', exception.message);
                    obj.stdout_eof_ = true;
                    obj.stdout_task_ = [];
                end
            end

            if ~obj.stderr_eof_ && ~isempty(obj.stderr_task_) && obj.stderr_task_.IsCompleted
                task = obj.stderr_task_;
                try
                    check_task(task, 'queue stderr read');
                    value = task.Result;
                    if is_dotnet_null(value)
                        obj.stderr_eof_ = true;
                        obj.stderr_task_ = [];
                    else
                        line = char(value);
                        obj.stderr_task_ = obj.stderr_.ReadLineAsync();
                        obj.append_stderr(line);
                    end
                    task.Dispose();
                catch exception
                    obj.transport_error_ = MException('trnrun:QueueReadFailed', ...
                        'Queue stderr read failed: %s', exception.message);
                    obj.stderr_eof_ = true;
                    obj.stderr_task_ = [];
                end
            end
        end

        function append_stderr(obj, line)
            obj.stderr_tail_{end + 1} = line;
            obj.stderr_chars_ = obj.stderr_chars_ + numel(line) + 1;
            while numel(obj.stderr_tail_) > obj.MaxStderrLines || ...
                    obj.stderr_chars_ > obj.MaxStderrChars
                removed = obj.stderr_tail_{1};
                obj.stderr_tail_(1) = [];
                obj.stderr_chars_ = obj.stderr_chars_ - numel(removed) - 1;
                obj.stderr_dropped_ = obj.stderr_dropped_ + 1;
            end
        end

        function throw_transport_error(obj)
            if ~isempty(obj.transport_error_)
                throwAsCaller(obj.transport_error_);
            end
        end

        function dispose_handles(obj, force)
            if obj.disposed_
                return
            end
            obj.disposed_ = true;

            streams = {obj.stdin_, obj.stdout_, obj.stderr_};
            for index = 1:numel(streams)
                try
                    if ~isempty(streams{index})
                        streams{index}.Dispose();
                    end
                catch
                end
            end
            try
                if ~isempty(obj.process_)
                    obj.process_.Dispose();
                end
            catch
            end
            try
                if ~isempty(obj.job_)
                    if force
                        try
                            obj.job_.Terminate(uint32(1));
                        catch
                        end
                    end
                    obj.job_.Dispose();
                end
            catch
            end
        end
    end
end

function result = is_dotnet_null(value)
% MATLAB maps a generic Task<string> null result to [] rather than System.String.
result = isempty(value) && ~ischar(value) && ~isstring(value) && ...
    ~isa(value, 'System.String');
end

function check_task(task, operation)
if task.IsCanceled
    error('trnrun:QueueTaskCanceled', '%s was canceled.', operation);
end
if task.IsFaulted
    cause = task.Exception.GetBaseException();
    error('trnrun:QueueTaskFaulted', '%s failed: %s', operation, char(cause.Message));
end
end

function validate_request(request)
if ~isstruct(request) || ~isscalar(request)
    error('trnrun:InvalidRequest', 'Queue request must be a scalar struct.');
end
required = {'runID', 'deckFile', 'runnerPath', 'runnerArgs'};
for index = 1:numel(required)
    if ~isfield(request, required{index})
        error('trnrun:InvalidRequest', ...
            'Queue request is missing field ''%s''.', required{index});
    end
end
if ~is_text(request.runID) || isempty(char(request.runID))
    error('trnrun:InvalidRequest', 'runID must be a nonempty string.');
end
if ~is_text(request.deckFile) || ~is_text(request.runnerPath)
    error('trnrun:InvalidRequest', ...
        'deckFile and runnerPath must be strings.');
end
if ~iscell(request.runnerArgs) || ...
        ~all(cellfun(@is_text, request.runnerArgs))
    error('trnrun:InvalidRequest', ...
        'runnerArgs must be a cell array containing only strings.');
end
end

function result = is_text(value)
result = (ischar(value) && isrow(value)) || ...
    (isstring(value) && isscalar(value) && ~ismissing(value));
end

function reject_nonfinite(value, location)
if isnumeric(value)
    if any(~isfinite(value(:)))
        error('trnrun:NonFiniteRequest', ...
            'Queue %s contains NaN or Inf.', location);
    end
elseif isstruct(value)
    names = fieldnames(value);
    for index = 1:numel(names)
        reject_nonfinite(value.(names{index}), [location '.' names{index}]);
    end
elseif iscell(value)
    for index = 1:numel(value)
        reject_nonfinite(value{index}, sprintf('%s{%d}', location, index));
    end
end
end
