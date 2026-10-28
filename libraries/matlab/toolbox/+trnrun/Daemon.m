classdef Daemon < handle
    %DAEMON A running trnrund: one JSON request line in, one response line out.
    %   Each method mirrors one trnrund command; REQUEST sends any raw one.
    %   See trnrund's README for every command.
    %
    %   Deleting the daemon makes trnrund cancel every simulation and exit.
    %
    %   Example:
    %       daemon = trnrun.Daemon(workers=2);
    %       simId = daemon.add("model.dck", trnrun.SimulationSettings(watchTmp=true));
    %       simulation = daemon.simulation(simId);

    properties (Access = private)
        process = []
        stdin = []
        stderrTask = []
    end

    properties (Constant, Access = private)
        CloseWaitMs = 10000 % trnrund's time to exit once its input closes
    end

    methods
        function obj = Daemon(options)
            %DAEMON Start trnrund and check that it answers.
            %   workers     - Simulations run at once (default: CPU count - 1).
            %   trnrundPath - trnrund executable (default: installed one).
            %   trnrunPath  - TRNRun executable (default: installed one).
            %   Raises trnrun:DaemonExited if trnrund exits before answering.

            arguments
                options.workers (1,1) double {mustBeInteger, mustBePositive}
                options.trnrundPath (1,1) string = ...
                    trnrun.internal.additionalSoftwareExecutable("TRNRunD", "trnrund.exe")
                options.trnrunPath (1,1) string = ...
                    trnrun.internal.additionalSoftwareExecutable("TRNRun", "trnrun.exe")
            end

            if ~ispc
                error('trnrun:UnsupportedPlatform', ...
                    'The MATLAB client supports Windows only.');
            end
            args = sprintf('"--trnrun:%s"', trnrun.internal.resolveFile(options.trnrunPath));
            if isfield(options, 'workers')
                args = sprintf('%s --workers:%d', args, options.workers);
            end

            psi = System.Diagnostics.ProcessStartInfo( ...
                char(trnrun.internal.resolveFile(options.trnrundPath)), char(args));
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            psi.RedirectStandardInput = true;
            psi.RedirectStandardOutput = true;
            psi.RedirectStandardError = true;
            psi.StandardOutputEncoding = System.Text.UTF8Encoding(false);
            psi.StandardErrorEncoding = System.Text.UTF8Encoding(false);

            % A failed constructor calls delete, which closes a started process.
            obj.process = System.Diagnostics.Process.Start(psi);
            % StandardInputEncoding is unavailable on .NET Framework.
            obj.stdin = System.IO.StreamWriter( ...
                obj.process.StandardInput.BaseStream, System.Text.UTF8Encoding(false));
            obj.stdin.AutoFlush = true;
            % Drained on a .NET thread, so a chatty stderr never blocks trnrund.
            obj.stderrTask = obj.process.StandardError.ReadToEndAsync();
            obj.request(struct('cmd', 'ready'));
        end

        function response = request(obj, request)
            %REQUEST Send a raw request struct; raises trnrun:RequestError or trnrun:DaemonExited.

            arguments
                obj (1,1) trnrun.Daemon
                request (1,1) struct
            end

            text = jsonencode(request);
            line = [];
            try
                obj.stdin.WriteLine(text);
                line = obj.process.StandardOutput.ReadLine();
            catch
                % A broken pipe or closed input: report why trnrund stopped.
            end
            % A null .NET string, end of output, arrives as numeric [].
            if isnumeric(line)
                error('trnrun:DaemonExited', '%s', obj.exitMessage());
            end
            response = jsondecode(char(line));
            if ~response.ok
                error('trnrun:RequestError', '%s', response.error);
            end
        end

        function simId = add(obj, deckFile, settings, options)
            %ADD Queue a deck with optional settings and label, and return its simId.

            arguments
                obj (1,1) trnrun.Daemon
                deckFile (1,1) string
                settings (1,1) trnrun.SimulationSettings = trnrun.SimulationSettings()
                options.label (1,1) string = missing
            end

            request = struct('cmd', 'add', ...
                'deckFile', trnrun.internal.resolveFile(deckFile), ...
                'trnrunOptions', settings.trnrunOptions());
            if ~ismissing(options.label)
                request.label = options.label;
            end
            response = obj.request(request);
            simId = response.simId;
        end

        function simulation = simulation(obj, simId, options)
            %SIMULATION Return one unreleased simulation; withLogs=true fills its logs.

            arguments
                obj (1,1) trnrun.Daemon
                simId (1,1) double
                options.withLogs (1,1) logical = false
            end

            response = obj.request(struct('cmd', 'simulation', ...
                'simId', simId, 'withLogs', options.withLogs));
            simulation = trnrun.Simulation(response.simulation);
        end

        function simulations = simulations(obj, state, options)
            %SIMULATIONS Return unreleased simulations in STATE, oldest first; withLogs=true fills logs.

            arguments
                obj (1,1) trnrun.Daemon
                state (1,:) string {mustBeMember(state, ["QUEUED", "RUNNING", "FINISHED"])}
                options.withLogs (1,1) logical = false
            end

            response = obj.request(struct('cmd', 'simulations', ...
                'state', {cellstr(state)}, 'withLogs', options.withLogs));
            records = response.simulations;
            if ~iscell(records)
                records = num2cell(records);
            end
            simulations = trnrun.Simulation.empty(1, 0);
            for index = 1:numel(records)
                simulations(index) = trnrun.Simulation(records{index});
            end
        end

        function cancel(obj, simId)
            %CANCEL Stop a queued or running simulation.

            obj.request(struct('cmd', 'cancel', 'simId', simId));
        end

        function release(obj, simId)
            %RELEASE Forget a finished simulation and its logs.

            obj.request(struct('cmd', 'release', 'simId', simId));
        end

        function close(obj)
            %CLOSE Close trnrund's input and wait for it to exit, killing it after 10 s.

            if isempty(obj.process)
                return
            end
            try
                obj.stdin.Close();
            catch
                % A broken input pipe is already closed.
            end
            if ~obj.process.WaitForExit(obj.CloseWaitMs)
                obj.process.Kill();
                obj.process.WaitForExit();
            end
        end

        function delete(obj)
            %DELETE Close trnrund.

            obj.close();
        end
    end

    methods (Access = private)
        function message = exitMessage(obj)
            %EXITMESSAGE Describe why trnrund stopped answering.

            if ~obj.process.WaitForExit(obj.CloseWaitMs)
                message = 'trnrund closed its output but did not exit';
                return
            end
            message = sprintf('trnrund exited with code %d', obj.process.ExitCode);
            if obj.stderrTask.Wait(1000)
                stderr = strtrim(char(obj.stderrTask.Result));
                if ~isempty(stderr)
                    message = [message ': ' stderr];
                end
            end
        end
    end
end
