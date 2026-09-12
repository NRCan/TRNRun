classdef QueueProcess < handle
    %QUEUEPROCESS Own one Windows queue process and its UTF-8 pipes.
    %   Q = trnrun.internal.QueueProcess(EXECUTABLE, MAXCONCURRENT) starts
    %   trnrunq with redirected input and output.
    %
    %   Q.send(REQUEST) writes one JSON request per line. Q.readLine(TIMEOUT)
    %   returns stdout as character vectors, or numeric [] at EOF. TIMEOUT
    %   limits the wait for a stdout line in seconds (default Inf), not
    %   simulation progress. Expiry terminates the queue and raises
    %   trnrun:QueueReadTimeout.
    %   Output is drained cooperatively while these methods wait; stderr
    %   history retains 200 lines of at most 1000 UTF-16 code units each.
    %   Truncated suffixes are not counted in stderr_dropped.
    %   SEND and WAIT have no timeout.
    %
    %   Q.close() ends submission without cancelling queued runs. Q.wait()
    %   drains output, waits for exit, and releases handles. Q.forceCleanup()
    %   or delete(Q) terminates only the queue, not its descendants.
    %   A failed or interrupted pump terminates the transport rather than
    %   attempting to resume a partially consumed read.

    properties (Access = private)
        process = []

        stdin = []
        stdout = []
        stderr = []
        stdoutTask = []
        stderrTask = []

        inputClosed (1,1) logical = false
        stdoutEof (1,1) logical = false
        stderrEof (1,1) logical = false
        disposed (1,1) logical = false
        pumping (1,1) logical = false

        processId double {mustBeScalarOrEmpty} = []
        exitCode double {mustBeScalarOrEmpty} = []
        pendingStdout (:,1) string = strings(0, 1)
        pendingStdoutHead (1,1) double = 1
        stderrTail (1,:) string = strings(1, 0)

        stderrDropped (1,1) double = 0
    end

    properties (Constant, Access = private)
        MaxStderrLines = 200
        MaxStderrLineChars = 1000
        MaxLinesPerPump = 1000
        PollSeconds = 0.01
    end

    methods
        function obj = QueueProcess(executable, maxConcurrent)
            %QUEUEPROCESS Start a Windows queue with redirected pipes.
            %   MAXCONCURRENT limits simultaneous runs.

            arguments
                executable (1,1) string {mustBeFile}
                maxConcurrent (1,1) double {mustBeInteger, mustBePositive}
            end

            if ~ispc
                error('trnrun:UnsupportedPlatform', ...
                    'The MATLAB client supports Windows only.');
            end

            [~, info] = fileattrib(executable);
            executable = info.Name;

            psi = System.Diagnostics.ProcessStartInfo();
            psi.FileName = executable;
            psi.Arguments = sprintf('--maxConcurrent:%.0f', maxConcurrent);
            psi.WorkingDirectory = fileparts(executable);
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            decoder = System.Text.UTF8Encoding(false, false);
            psi.StandardOutputEncoding = decoder;
            psi.StandardErrorEncoding = decoder;

            % Failed construction invokes delete to clean up a started process.
            obj.process = System.Diagnostics.Process();
            obj.process.StartInfo = psi;
            obj.process.Start();
            obj.processId = double(obj.process.Id);

            % StandardInputEncoding is unavailable on .NET Framework.
            obj.stdin = System.IO.StreamWriter( ...
                obj.process.StandardInput.BaseStream, ...
                System.Text.UTF8Encoding(false, true));
            obj.stdin.AutoFlush = true;
            obj.stdout = obj.process.StandardOutput;
            obj.stderr = obj.process.StandardError;
            obj.stdoutTask = obj.stdout.ReadLineAsync();
            obj.stderrTask = obj.stderr.ReadLineAsync();
        end

        function send(obj, request)
            %SEND Write a JSON request while draining output.
            %   The queue validates request fields.

            arguments
                obj (1,1) trnrun.internal.QueueProcess
                request (1,1) struct
            end

            if obj.inputClosed
                error('trnrun:QueueInputClosed', ...
                    'The queue is no longer accepting submissions.');
            end

            line = jsonencode(request);
            try
                task = obj.stdin.WriteLineAsync(line);
                while ~task.IsCompleted
                    obj.pumpOrPause();
                end
                checkTask(task, "stdin write");
            catch exception
                obj.forceCleanup();
                rethrow(exception);
            end
        end

        function line = readLine(obj, timeout)
            %READLINE Return stdout as char or [] at EOF.
            %   The optional timeout limits the wait in seconds.

            arguments
                obj (1,1) trnrun.internal.QueueProcess
                timeout (1,1) double {mustBePositive} = Inf
            end

            started = tic;
            while obj.pendingStdoutHead > numel(obj.pendingStdout)
                if obj.stdoutEof
                    line = [];
                    return
                end
                if toc(started) >= timeout
                    obj.forceCleanup();
                    error('trnrun:QueueReadTimeout', ...
                        'No stdout line became available within %g seconds.', timeout);
                end
                obj.pumpOrPause();
            end

            line = char(obj.pendingStdout(obj.pendingStdoutHead));
            obj.pendingStdoutHead = obj.pendingStdoutHead + 1;
            if obj.pendingStdoutHead > 256 && ...
                    obj.pendingStdoutHead > numel(obj.pendingStdout) / 2
                obj.pendingStdout(1:obj.pendingStdoutHead - 1) = [];
                obj.pendingStdoutHead = 1;
            end
        end

        function close(obj)
            %CLOSE End submission without cancelling runs.
            %   Repeated calls are harmless.

            if obj.inputClosed
                return
            end

            obj.inputClosed = true;
            try
                obj.stdin.Close();
            catch
                % A broken input pipe is already effectively closed.
            end
        end

        function exitCode = wait(obj)
            %WAIT Close input, drain output, and reap the queue.
            %   Return the cached exit code.

            if ~obj.disposed
                obj.close();
                while ~(obj.stdoutEof && obj.stderrEof)
                    obj.pumpOrPause();
                end
                while ~obj.process.WaitForExit(0)
                    pause(obj.PollSeconds);
                end
                obj.exitCode = double(obj.process.ExitCode);
                obj.release();
            end
            exitCode = obj.exitCode;
        end

        function value = diagnostics(obj)
            %DIAGNOSTICS Return cached process identity, exit state, and bounded stderr.

            exitCode = obj.exitCode;
            if isempty(exitCode) && ~obj.disposed && obj.process.HasExited
                exitCode = double(obj.process.ExitCode);
            end
            value = struct( ...
                'pid', obj.processId, ...
                'exit_code', exitCode, ...
                'stderr', {cellstr(obj.stderrTail)}, ...
                'stderr_dropped', obj.stderrDropped);
        end

        function forceCleanup(obj)
            %FORCECLEANUP Terminate the queue, tolerating partial initialization.

            if obj.disposed
                return
            end

            try
                % ponytail: queue only; restore Job Object ownership for descendant cleanup.
                obj.process.Kill();
            catch
            end
            try
                if obj.process.WaitForExit(2000)
                    obj.exitCode = double(obj.process.ExitCode);
                end
            catch
            end
            obj.release();
        end

        function delete(obj)
            %DELETE Release this transport and terminate the queue.

            obj.forceCleanup();
        end
    end

    methods (Access = private)
        function pumpOrPause(obj)
            %PUMPORPAUSE Drain a bounded batch and yield, sleeping only when idle.

            if obj.pump()
                pause(0);
            else
                pause(obj.PollSeconds);
            end
        end

        function progressed = pump(obj)
            %PUMP Service both streams fairly and abort if a batch does not complete.

            % onCleanup also handles Ctrl+C, which does not enter catch blocks.
            guard = onCleanup(@() obj.abortIncompletePump()); %#ok<NASGU>
            obj.pumping = true;
            progressed = false;
            for pass = 1:obj.MaxLinesPerPump
                stdoutReady = obj.pumpStream("stdout");
                stderrReady = obj.pumpStream("stderr");
                if ~(stdoutReady || stderrReady)
                    break
                end
                progressed = true;
            end
            obj.pumping = false;
        end

        function abortIncompletePump(obj)
            %ABORTINCOMPLETEPUMP Prevent reuse of partially consumed stream tasks.

            if obj.pumping
                obj.forceCleanup();
            end
        end

        function got = pumpStream(obj, name)
            %PUMPSTREAM Consume one completed stdout or stderr read and schedule the next.

            taskName = name + "Task";
            task = obj.(taskName);
            % EOF and release both clear the task.
            got = ~isempty(task) && task.IsCompleted;
            if ~got
                return
            end

            checkTask(task, name + " read");
            value = task.Result;
            % A null Task<string> result maps to numeric []; '' is a line.
            if isnumeric(value) && isempty(value)
                obj.(name + "Eof") = true;
                obj.(taskName) = [];
                return
            end

            if name == "stdout"
                obj.pendingStdout(end + 1, 1) = string(char(value));
            else
                obj.appendStderr(char(value));
            end
            stream = obj.(name);
            obj.(taskName) = stream.ReadLineAsync();
        end

        function appendStderr(obj, line)
            %APPENDSTDERR Retain recent stderr, truncating overlong lines.

            % ponytail: only history is bounded; use chunked reads to bound peak memory.
            count = min(numel(line), obj.MaxStderrLineChars);
            % Do not leave half a UTF-16 surrogate pair at the truncation boundary.
            if count < numel(line) && count > 0 && ...
                    line(count) >= char(55296) && line(count) <= char(56319)
                count = count - 1;
            end
            obj.stderrTail(end + 1) = string(line(1:count));
            if numel(obj.stderrTail) > obj.MaxStderrLines
                obj.stderrTail(1) = [];
                obj.stderrDropped = obj.stderrDropped + 1;
            end
        end

        function release(obj)
            %RELEASE Dispose streams and process handles.

            if obj.disposed
                return
            end

            obj.disposed = true;
            obj.inputClosed = true;
            obj.stdoutEof = true;
            obj.stderrEof = true;
            obj.pumping = false;
            obj.stdoutTask = [];
            obj.stderrTask = [];

            handles = {obj.stdin, obj.stdout, obj.stderr, obj.process};
            for index = 1:numel(handles)
                try
                    if ~isempty(handles{index})
                        handles{index}.Dispose();
                    end
                catch
                    % Cleanup must tolerate partially initialized handles.
                end
            end
        end
    end
end

function checkTask(task, operation)
    %CHECKTASK Report failure of a completed pipe operation.

    if task.IsFaulted
        cause = task.Exception.GetBaseException();
        error('trnrun:QueuePipeFailed', ...
            'Queue %s failed: %s', operation, char(cause.Message));
    end
end
