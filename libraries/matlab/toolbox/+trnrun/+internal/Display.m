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
        activeText = ''
    end

    properties (Constant, Access = private)
        PathWidth = 32
        ProgressBarWidth = 20
        MillisecondsPerSecond = 1000
    end

    methods
        function obj = Display(refreshInterval)
            %DISPLAY Create a throttled simulation summary display.
            %   OBJ = trnrun.internal.Display(REFRESHINTERVAL) sets the minimum
            %   interval between ordinary refreshes, in seconds. The interval
            %   must be a real, finite numeric scalar; values at or below zero
            %   disable all simulation output.
            %
            %   The first simulation and every finished simulation force an
            %   immediate redraw when enabled. Additional starts are throttled.
            %   Deleting the display leaves active progress visible and moves
            %   the Command Window prompt to a new line.

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
            wasEmpty = isempty(obj.activeIds);
            key = sprintf('%.0f', simulation.id);
            if ~isKey(obj.active, key)
                obj.active(key) = simulation;
                obj.activeIds{end + 1} = key;
            end
            obj.refresh(wasEmpty);
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
            drawnow nocallbacks
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
            obj.updateActive(text);
            obj.lastRefresh = tic;
        end

        function delete(obj)
            %DELETE Leave interrupted progress visible on its own prompt line.

            if ~isempty(obj.activeText)
                fprintf('\n');
                obj.activeText = '';
            end
        end
    end

    methods (Access = private)
        function eraseActive(obj)
            %ERASEACTIVE Erase the active summary block using backspaces.

            if ~isempty(obj.activeText)
                fprintf('%s', repmat(sprintf('\b'), 1, numel(obj.activeText)));
                obj.activeText = '';
            end
        end

        function updateActive(obj, text)
            %UPDATEACTIVE Replace the active block only when its text changed.

            if strcmp(obj.activeText, text)
                return
            end
            obj.eraseActive();
            fprintf('%s', text);
            obj.activeText = text;
        end

        function line = renderLine(obj, simulation)
            %RENDERLINE Format one simulation as a single status summary line.

            path = char(simulation.deckPath);
            if numel(path) > obj.PathWidth
                path = ['...' path((end - obj.PathWidth + 4):end)];
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
                elapsed = formatHhmmss( ...
                    simulation.progress.elapsed / obj.MillisecondsPerSecond);
                eta = formatHhmmss( ...
                    simulation.progress.eta / obj.MillisecondsPerSecond);
            end

            bar = progressBar(0, obj.ProgressBarWidth);
            simPercent = '';
            if ~isempty(percent)
                bar = progressBar(percent, obj.ProgressBarWidth);
                simPercent = sprintf('(%.0f%%)', 100 * percent);
            end

            simProgress = '- / -';
            if ~isempty(simulation.progress) && ~isempty(simulation.configEvent)
                simProgress = sprintf('%6s / %6s', ...
                    formatNumber(simulation.progress.time), ...
                    formatNumber(simulation.configEvent.stop));
            end

            logs = sprintf('N:%d W:%d F:%d', ...
                simulation.notices, simulation.warnings, simulation.fatals);
            line = sprintf( ...
                '[%d] %s | Status: %-10s | Logs: %-12s | Elapsed: %-8s | ETA: %-8s | %s %s %-6s', ...
                simulation.id, path, status, logs, elapsed, eta, ...
                bar, simProgress, simPercent);
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

function text = progressBar(percent, width)
    %PROGRESSBAR Return a fixed-width ASCII completion bar.

    filled = min(max(fix(width * percent), 0), width);
    text = ['[' repmat('#', 1, filled) repmat('-', 1, width - filled) ']'];
end

function text = formatNumber(value)
    %FORMATNUMBER Round a number and insert thousands separators.

    text = sprintf('%.0f', value);
    sign = '';
    if text(1) == '-'
        sign = '-';
        text = text(2:end);
    end

    firstGroupLength = mod(numel(text), 3);
    if firstGroupLength == 0
        firstGroupLength = 3;
    end

    groupCount = 1 + (numel(text) - firstGroupLength) / 3;
    groups = cell(1, groupCount);
    groups{1} = text(1:firstGroupLength);
    for groupIndex = 2:groupCount
        first = firstGroupLength + 3 * (groupIndex - 2) + 1;
        groups{groupIndex} = text(first:(first + 2));
    end
    text = [sign strjoin(groups, ',')];
end
