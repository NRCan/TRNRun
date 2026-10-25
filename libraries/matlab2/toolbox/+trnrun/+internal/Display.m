classdef Display < handle
    %DISPLAY Show throttled live progress in a uifigure text window.
    %   Finished simulations are printed once to the Command Window. Closing
    %   the window stops live updates only, not the runs or final output.
    %
    %   Example:
    %       display = trnrun.internal.Display(1);  % redraw at most every second; <= 0 disables
    %       display.simulationStarted(simulation);
    %       display.simulationFinished(simulation);
    %       display.refresh();

    properties (Access = private)
        enabled = true
        refreshInterval = 1
        lastRefresh
        sims = trnrun.Simulation.empty(1, 0)
        finished = false(1, 0)
        activeText = ''
        rowStates = cell(1, 0)
        rowLines = cell(1, 0)
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
            %DISPLAY Create a display redrawing at most every REFRESHINTERVAL seconds.

            validateattributes(refreshInterval, {'numeric'}, ...
                {'real', 'scalar', 'finite'}, 'trnrun.internal.Display', 'refreshInterval');
            refreshInterval = double(refreshInterval);
            obj.enabled = refreshInterval > 0;
            obj.refreshInterval = refreshInterval;
            obj.lastRefresh = tic;
        end

        function simulationStarted(obj, simulation)
            %SIMULATIONSTARTED Add a simulation to the active display and redraw.

            if ~obj.enabled
                return
            end
            wasEmpty = isempty(obj.sims);
            if ~any(obj.sims == simulation)
                obj.sims(end + 1) = simulation;
                obj.finished(end + 1) = false;
                obj.rowStates{end + 1} = [];
                obj.rowLines{end + 1} = '';
            end
            obj.refresh(wasEmpty);
        end

        function simulationFinished(obj, simulation)
            %SIMULATIONFINISHED Queue a started simulation's final summary for the next refresh.

            if ~obj.enabled
                return
            end
            obj.finished(obj.sims == simulation) = true;
        end

        function refresh(obj, force)
            %REFRESH Print finished summaries and redraw; force=true ignores the interval.

            if nargin < 2
                force = false;
            end
            allFinished = ~isempty(obj.sims) && all(obj.finished);
            if ~obj.enabled || (~force && ~allFinished && ...
                    toc(obj.lastRefresh) < obj.refreshInterval)
                return
            end
            done = obj.sims(obj.finished);
            obj.sims = obj.sims(~obj.finished);
            obj.rowStates = obj.rowStates(~obj.finished);
            obj.rowLines = obj.rowLines(~obj.finished);
            obj.finished = false(1, numel(obj.sims));

            if ~isempty(done)
                fprintf('%s\n', obj.renderLines(done));
            end
            text = obj.renderLines(obj.sims, true);
            obj.updateActive(text);
            obj.activeText = text;
            obj.lastRefresh = tic;
        end

        function delete(obj)
            %DELETE Close the window and print interrupted progress.

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
        function text = renderLines(obj, sims, useCache)
            %RENDERLINES Join summaries, reusing unchanged active rows.

            if nargin < 3 || ~useCache
                text = strjoin(arrayfun(@(sim) obj.renderLine(sim), sims, ...
                    'UniformOutput', false), newline);
                return
            end
            for index = 1:numel(sims)
                sim = sims(index);
                % Snapshot the rendered fields: the handle itself mutates in place.
                state = {sim.state, sim.trnrunStatus, sim.percent, sim.simTime, ...
                    sim.elapsedMs, sim.etaMs, sim.stopTime, ...
                    sim.notices, sim.warnings, sim.fatals};
                if ~isequaln(obj.rowStates{index}, state)
                    obj.rowLines{index} = obj.renderLine(sim);
                    obj.rowStates{index} = state;
                end
            end
            text = strjoin(obj.rowLines, newline);
        end

        function updateActive(obj, text)
            %UPDATEACTIVE Show TEXT in the window, opening it on first use.

            if isempty(obj.window) && ~isempty(text)
                obj.window = uifigure('Name', 'TRNRun progress', ...
                    'Position', [100 100 1200 520], 'Visible', 'off');
                layout = uigridlayout(obj.window, [1 1]);
                obj.textArea = uitextarea(layout, 'Editable', 'off', ...
                    'FontName', get(groot, 'FixedWidthFontName'), ...
                    'WordWrap', 'off');
                obj.textArea.Value = splitlines(string(text));
                obj.window.Visible = 'on';
            elseif ~isempty(obj.textArea) && isgraphics(obj.textArea) && ...
                    ~strcmp(obj.activeText, text)
                obj.textArea.Value = splitlines(string(text));
            else
                % A deleted window handle stays nonempty: never reopen it.
                return
            end
            drawnow limitrate nocallbacks
        end

        function line = renderLine(obj, simulation)
            %RENDERLINE Format one simulation as a status line.

            name = simulation.label;
            if ismissing(name) || name == ""
                name = simulation.deckFile;
            end
            path = char(name);
            if numel(path) > obj.PathWidth
                path = ['...' path((end - obj.PathWidth + 4):end)];
            end

            % Before TRNRun reports a status, show the state.
            status = simulation.trnrunStatus;
            if ismissing(status)
                status = simulation.state;
            end
            status = char(status);

            percent = 0;
            simPercent = '';
            elapsed = '--:--:--';
            eta = '--:--:--';
            simProgress = '- / -';
            % NaN until TRNRun's first PROGRESS event, which needs Type3830.
            if ~isnan(simulation.percent)
                percent = simulation.percent;
                simPercent = sprintf('(%.0f%%)', 100 * percent);
                elapsed = formatHhmmss(simulation.elapsedMs / obj.MillisecondsPerSecond);
                eta = formatHhmmss(simulation.etaMs / obj.MillisecondsPerSecond);
                if ~isnan(simulation.stopTime)
                    simProgress = sprintf('%6s / %6s', ...
                        formatNumber(simulation.simTime), ...
                        formatNumber(simulation.stopTime));
                end
            end

            logs = sprintf('N:%d W:%d F:%d', ...
                simulation.notices, simulation.warnings, simulation.fatals);
            line = sprintf( ...
                '[%d] %-*s | Status: %-10s | Logs: %-12s | Elapsed: %-8s | ETA: %-8s | %s %s %-6s', ...
                simulation.simId, obj.PathWidth, path, status, logs, elapsed, eta, ...
                progressBar(percent, obj.ProgressBarWidth), simProgress, simPercent);
        end
    end
end

function text = formatHhmmss(seconds)
    %FORMATHHMMSS Format seconds as HH:MM:SS; NaN and negatives read as 00:00:00.

    if isnan(seconds) || seconds < 0
        seconds = 0;
    elseif isinf(seconds)
        text = 'Inf';
        return
    end
    seconds = fix(seconds);
    hours = floor(seconds / 3600);
    minutes = floor(mod(seconds, 3600) / 60);
    text = sprintf('%02.0f:%02.0f:%02.0f', hours, minutes, mod(seconds, 60));
end

function text = progressBar(percent, width)
    %PROGRESSBAR Return a fixed-width ASCII completion bar.

    filled = min(max(fix(width * percent), 0), width);
    text = ['[' repmat('#', 1, filled) repmat('-', 1, width - filled) ']'];
end

function text = formatNumber(value)
    %FORMATNUMBER Round a number and insert thousands separators.

    text = regexprep(sprintf('%.0f', value), '\d(?=(\d{3})+$)', '$0,');
end
