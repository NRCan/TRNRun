classdef ScriptedQueueProcess < handle
    %SCRIPTEDQUEUEPROCESS Deterministic in-memory queue transport for unit tests.

    properties
        lines
        sent = {}
        closed = false
        waited = false
        forced = false
        exit_code = 0
        before_send = []
    end

    properties (Access = private)
        next_line_ = 1
    end

    methods
        function obj = ScriptedQueueProcess(lines, exit_code)
            if nargin < 1
                lines = {};
            end
            if nargin >= 2
                obj.exit_code = exit_code;
            end
            obj.lines = lines;
        end

        function send(obj, request)
            if obj.closed
                error('testsupport:Closed', 'Scripted transport input is closed.');
            end
            if ~isempty(obj.before_send)
                obj.before_send(request);
            end
            obj.sent{end + 1} = request;
        end

        function line = readLine(obj)
            if obj.next_line_ > numel(obj.lines)
                line = [];
                return
            end
            line = obj.lines{obj.next_line_};
            obj.next_line_ = obj.next_line_ + 1;
        end

        function close(obj)
            obj.closed = true;
        end

        function value = wait(obj)
            obj.waited = true;
            value = obj.exit_code;
        end

        function forceCleanup(obj)
            obj.forced = true;
            obj.closed = true;
        end

        function value = diagnostics(~)
            value = struct('pid', [], 'exit_code', [], ...
                'stderr', {{}}, 'stderr_dropped', 0);
        end
    end
end
