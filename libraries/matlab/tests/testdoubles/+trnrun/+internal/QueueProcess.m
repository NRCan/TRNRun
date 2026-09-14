classdef QueueProcess < handle
    %QUEUEPROCESS Scripted stand-in for the real TRNRun queue transport.
    %   This class deliberately shares the name of
    %   trnrun.internal.QueueProcess. SimulationManagerTest puts the folder
    %   that contains it ahead of the toolbox on the MATLAB path, so the
    %   manager talks to this object instead of starting a real process.
    %
    %   MATLAB caches class definitions while instances exist, so shadowing
    %   only takes effect when no real queue is alive. SimulationManagerTest
    %   asserts that the shadow is in place before it runs.
    %
    %   Each instance registers itself under the appdata key
    %   trnrun.internal.QueueProcess.MockKey, so a test can reach the
    %   transport that a manager created for itself:
    %
    %       manager = trnrun.SimulationManager(trnrunqPath="mock.exe");
    %       queue = getappdata(0, trnrun.internal.QueueProcess.MockKey);
    %       queue.script = ["...", "..."];
    %
    %   READLINE walks script in order and then reports EOF, matching the
    %   real transport, which returns numeric [] once stdout is drained.

    properties (Constant)
        MockKey = 'TRNRunMockQueueProcess'
    end

    properties
        script (1,:) string = strings(1, 0)     % stdout lines, in order
        exitCode (1,1) double = 0               % value returned by wait
        sendError (1,1) string = string(missing)    % identifier raised by send
        readError (1,1) string = string(missing)    % identifier raised by readLine
        readHook = []                           % called with obj before each read
        stderr (1,:) string = strings(1, 0)     % reported by diagnostics
        stderrDropped (1,1) double = 0
        diagnosticsError (1,1) logical = false  % make diagnostics throw
    end

    properties (SetAccess = private)
        executable (1,1) string
        maxConcurrent (1,1) double
        sent = {}                               % requests passed to send
        calls (1,:) string = strings(1, 0)      % method names, in call order
        scriptHead (1,1) double = 1
        inputClosed (1,1) logical = false
        cleanedUp (1,1) logical = false
    end

    methods
        function obj = QueueProcess(executable, maxConcurrent)
            %QUEUEPROCESS Record the launch arguments and publish this instance.

            obj.executable = executable;
            obj.maxConcurrent = maxConcurrent;
            setappdata(0, obj.MockKey, obj);
        end

        function send(obj, request)
            %SEND Record a request, or raise the configured identifier.

            obj.calls(end + 1) = "send";
            if ~ismissing(obj.sendError)
                error(char(obj.sendError), 'Mock queue send failed.');
            end
            obj.sent{end + 1} = request;
        end

        function line = readLine(obj, timeout) %#ok<INUSD>
            %READLINE Return the next scripted line, or numeric [] at EOF.

            obj.calls(end + 1) = "readLine";
            if ~isempty(obj.readHook)
                hook = obj.readHook;
                obj.readHook = [];
                hook(obj);
            end
            if ~ismissing(obj.readError)
                error(char(obj.readError), 'Mock queue read failed.');
            end
            if obj.scriptHead > numel(obj.script)
                line = [];
                return
            end
            line = char(obj.script(obj.scriptHead));
            obj.scriptHead = obj.scriptHead + 1;
        end

        function close(obj)
            %CLOSE Record the end of submission.

            obj.calls(end + 1) = "close";
            obj.inputClosed = true;
        end

        function exitCode = wait(obj)
            %WAIT Record the reap and return the configured exit code.

            obj.calls(end + 1) = "wait";
            obj.inputClosed = true;
            exitCode = obj.exitCode;
        end

        function value = diagnostics(obj)
            %DIAGNOSTICS Return the configured queue stderr snapshot.

            obj.calls(end + 1) = "diagnostics";
            if obj.diagnosticsError
                error('trnrun:MockDiagnosticsFailed', ...
                    'Mock queue diagnostics failed.');
            end
            value = struct( ...
                'pid', 4242, ...
                'exit_code', obj.exitCode, ...
                'stderr', {cellstr(obj.stderr)}, ...
                'stderr_dropped', obj.stderrDropped);
        end

        function forceCleanup(obj)
            %FORCECLEANUP Record termination of the transport.

            obj.calls(end + 1) = "forceCleanup";
            obj.cleanedUp = true;
        end

        function queue(obj, lines)
            %QUEUE Append stdout lines for later reads.

            obj.script = [obj.script, string(lines)];
        end

        function names = callsSince(obj, mark)
            %CALLSSINCE Return the method names recorded after index MARK.

            names = obj.calls(mark + 1:end);
        end
    end
end
