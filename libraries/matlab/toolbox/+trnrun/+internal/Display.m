classdef Display < handle
    %DISPLAY Show a throttled in-place Command Window simulation summary.
    %   Tracks active simulations and prints a permanent summary when each
    %   finishes. Active summaries include status, progress, timing, and
    %   diagnostic counts, and are redrawn at the configured interval.
    %
    %   Backspace redraws assume no unrelated output within the active block.

    properties (Access = private)
        enabled = true
        refreshInterval = 1
        lastRefresh
        active
        activeIds = {}
        activeTextLength = 0
    end

    methods
        function obj = Display(refreshInterval)
            %DISPLAY Create a throttled simulation summary display.
            %   OBJ = trnrun.internal.Display(REFRESHINTERVAL) sets the minimum
            %   interval between ordinary refreshes, in seconds. The interval
            %   must be a real, finite numeric scalar; values at or below zero
            %   disable all simulation output.
            %
            %   Simulation start and finish events force an immediate redraw
            %   when enabled. Deleting the display leaves active progress
            %   visible and moves the Command Window prompt to a new line.

            validateattributes(refreshInterval, {'numeric'}, ...
                {'real', 'scalar', 'finite'}, 'trnrun.internal.Display', 'refreshInterval');
            refreshInterval = double(refreshInterval);
            obj.enabled = refreshInterval > 0;
            obj.refreshInterval = refreshInterval;
            obj.lastRefresh = tic;
            obj.active = containers.Map('KeyType', 'char', 'ValueType', 'any');
        end

        function simulationStarted(obj, simulation)
            %SIMULATIONSTARTED Add a simulation to the active display and redraw.

            if ~obj.enabled
                return
            end
            key = sprintf('%.0f', simulation.id);
            if ~isKey(obj.active, key)
                obj.active(key) = simulation;
                obj.activeIds{end + 1} = key;
            end
            obj.refresh(true);
        end

        function simulationFinished(obj, simulation)
            %SIMULATIONFINISHED Remove a simulation and print its final summary.

            if ~obj.enabled
                return
            end
            key = sprintf('%.0f', simulation.id);
            if isKey(obj.active, key)
                remove(obj.active, key);
                obj.activeIds(strcmp(obj.activeIds, key)) = [];
            end
            obj.eraseActive();
            fprintf('%s\n', obj.renderLine(simulation));
            obj.refresh(true);
        end

        function refresh(obj, force)
            %REFRESH Redraw active summaries, optionally bypassing the interval.

            if nargin < 2
                force = false;
            end
            if ~obj.enabled || (~force && toc(obj.lastRefresh) < obj.refreshInterval)
                return
            end
            lines = cell(1, numel(obj.activeIds));
            for index = 1:numel(obj.activeIds)
                key = obj.activeIds{index};
                lines{index} = obj.renderLine(obj.active(key));
            end
            text = strjoin(lines, newline);
            obj.eraseActive();
            fprintf('%s', text);
            obj.activeTextLength = numel(text);
            obj.lastRefresh = tic;
        end

        function delete(obj)
            %DELETE Leave interrupted progress visible on its own prompt line.

            if obj.activeTextLength > 0
                fprintf('\n');
                obj.activeTextLength = 0;
            end
        end
    end

    methods (Access = private)
        function eraseActive(obj)
            %ERASEACTIVE Erase the active summary block using backspaces.

            if obj.activeTextLength > 0
                fprintf('%s', repmat(sprintf('\b'), 1, obj.activeTextLength));
                obj.activeTextLength = 0;
            end
        end

        function line = renderLine(~, simulation)
            %RENDERLINE Format one simulation as a single status summary line.

            path = char(simulation.deckPath);
            width = 32;
            if numel(path) > width
                path = ['...' path((end - width + 4):end)];
            end

            status = '';
            if ~isempty(simulation.status)
                status = char(simulation.status.status);
            end

            percent = [];
            elapsed = '--:--:--';
            eta = '--:--:--';
            if ~isempty(simulation.progress)
                percent = simulation.progress.percent;
                elapsed = formatHhmmss(simulation.progress.elapsed / 1000);
                eta = formatHhmmss(simulation.progress.eta / 1000);
            end
            if isempty(percent)
                progress = '  ---%';
            else
                progress = sprintf('%6.1f%%', 100 * percent);
            end

            line = sprintf('[%d] %-32s | %-10s | %s | elapsed %s | ETA %s | N:%d W:%d F:%d', ...
                simulation.id, path, status, progress, elapsed, eta, ...
                simulation.notices, simulation.warnings, simulation.fatals);
        end
    end
end

function text = formatHhmmss(seconds)
    %FORMATHHMMSS Format seconds as HH:MM:SS, truncating and clamping to zero.

    seconds = max(fix(seconds), 0);
    hours = fix(seconds / 3600);
    seconds = seconds - hours * 3600;
    minutes = fix(seconds / 60);
    seconds = seconds - minutes * 60;
    text = sprintf('%02d:%02d:%02d', hours, minutes, seconds);
end
