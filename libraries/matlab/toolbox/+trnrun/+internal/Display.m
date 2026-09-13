classdef Display < handle
    %DISPLAY Show throttled live progress in a native MATLAB text window.
    %   Completed summaries are appended to the Command Window. Closing the
    %   progress window disables live updates, not simulations or final output.

    properties (Access = private)
        enabled = true
        refreshInterval = 1
        lastRefresh
        active
        activeIds = {}
        finishedIds = {}
        activeText = ''
        window = []
        textArea = []
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
            %   The first simulation forces a redraw. Completions are batched
            %   into the next refresh; the last completion bypasses throttling.
            %   The progress window opens on the first simulation. Deleting
            %   the display closes it and prints any interrupted progress.

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
            %SIMULATIONFINISHED Queue a final summary for the next refresh.

            if ~obj.enabled
                return
            end
            key = sprintf('%.0f', simulation.id);
            if isKey(obj.active, key) && ~ismember(key, obj.finishedIds)
                obj.finishedIds{end + 1} = key;
            end
        end

        function refresh(obj, force)
            %REFRESH Redraw active summaries, optionally bypassing the interval.

            if nargin < 2
                force = false;
            end
            allFinished = ~isempty(obj.activeIds) && ...
                numel(obj.finishedIds) == numel(obj.activeIds);
            if ~obj.enabled || (~force && ~allFinished && ...
                    toc(obj.lastRefresh) < obj.refreshInterval)
                return
            end
            finalLines = cell(1, numel(obj.finishedIds));
            for index = 1:numel(obj.finishedIds)
                key = obj.finishedIds{index};
                finalLines{index} = [obj.renderLine(obj.active(key)) newline];
                remove(obj.active, key);
            end
            obj.activeIds(ismember(obj.activeIds, obj.finishedIds)) = [];
            obj.finishedIds = {};
            lines = cell(1, numel(obj.activeIds));
            for index = 1:numel(obj.activeIds)
                key = obj.activeIds{index};
                lines{index} = obj.renderLine(obj.active(key));
            end
            text = strjoin(lines, newline);
            if ~isempty(finalLines)
                fprintf('%s', [finalLines{:}]);
            end
            obj.updateActive(text);
            obj.activeText = text;
            obj.lastRefresh = tic;
        end

        function delete(obj)
            %DELETE Close the window and preserve interrupted progress as text.

            if isgraphics(obj.window)
                delete(obj.window);
            end
            obj.refresh(true);
            if ~isempty(obj.activeText)
                fprintf('%s\n', obj.activeText);
                obj.activeText = '';
            end
        end
    end

    methods (Access = private)
        function updateActive(obj, text)
            %UPDATEACTIVE Assign the whole live block without clearing it first.

            if isempty(obj.window) && ~isempty(text)
                obj.window = uifigure('Name', 'TRNRun progress', ...
                    'Position', [100 100 1200 520], 'Visible', 'off');
                layout = uigridlayout(obj.window, [1 1]);
                obj.textArea = uitextarea(layout, 'Editable', 'off', ...
                    'FontName', get(groot, 'FixedWidthFontName'), ...
                    'WordWrap', 'off');
                obj.textArea.Value = splitlines(string(text));
                obj.window.Visible = 'on';
            elseif isgraphics(obj.textArea) && ~strcmp(obj.activeText, text)
                obj.textArea.Value = splitlines(string(text));
            else
                % A deleted window handle stays nonempty: never reopen it.
                return
            end
            drawnow limitrate nocallbacks
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
