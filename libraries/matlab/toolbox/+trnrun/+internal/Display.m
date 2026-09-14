classdef Display < handle
    %DISPLAY Show throttled live progress in a native MATLAB text window.
    %   Completed summaries are appended to the Command Window. Closing the
    %   progress window disables live updates, not simulations or final output.

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
            %SIMULATIONFINISHED Queue a final summary for the next refresh.
            %   Simulations that were never started are ignored.

            if ~obj.enabled
                return
            end
            obj.finished(obj.sims == simulation) = true;
        end

        function refresh(obj, force)
            %REFRESH Redraw active summaries, optionally bypassing the interval.

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
        function text = renderLines(obj, sims, useCache)
            %RENDERLINES Join summaries, reusing unchanged active rows.

            if nargin < 3 || ~useCache
                text = strjoin(arrayfun(@(sim) obj.renderLine(sim), sims, ...
                    'UniformOutput', false), newline);
                return
            end
            for index = 1:numel(sims)
                sim = sims(index);
                % Value snapshots detect updates to mutable simulation handles.
                % The immutable id and deckPath need not be compared.
                state = {sim.status, sim.progress, sim.configEvent, ...
                    sim.notices, sim.warnings, sim.fatals};
                if ~isequaln(obj.rowStates{index}, state)
                    obj.rowLines{index} = obj.renderLine(sim);
                    obj.rowStates{index} = state;
                end
            end
            text = strjoin(obj.rowLines, newline);
        end

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
            %RENDERLINE Format one simulation as a single status summary line.

            path = char(simulation.deckPath);
            if numel(path) > obj.PathWidth
                path = ['...' path((end - obj.PathWidth + 4):end)];
            end

            status = '';
            if ~isempty(simulation.status)
                status = char(simulation.status.status);
            end

            percent = 0;
            simPercent = '';
            elapsed = '--:--:--';
            eta = '--:--:--';
            simProgress = '- / -';
            if ~isempty(simulation.progress)
                percent = simulation.progress.percent;
                simPercent = sprintf('(%.0f%%)', 100 * percent);
                elapsed = formatHhmmss( ...
                    simulation.progress.elapsed / obj.MillisecondsPerSecond);
                eta = formatHhmmss( ...
                    simulation.progress.eta / obj.MillisecondsPerSecond);
                if ~isempty(simulation.configEvent)
                    simProgress = sprintf('%6s / %6s', ...
                        formatNumber(simulation.progress.time), ...
                        formatNumber(simulation.configEvent.stop));
                end
            end

            logs = sprintf('N:%d W:%d F:%d', ...
                simulation.notices, simulation.warnings, simulation.fatals);
            line = sprintf( ...
                '[%d] %-*s | Status: %-10s | Logs: %-12s | Elapsed: %-8s | ETA: %-8s | %s %s %-6s', ...
                simulation.id, obj.PathWidth, path, status, logs, elapsed, eta, ...
                progressBar(percent, obj.ProgressBarWidth), simProgress, simPercent);
        end
    end
end

function text = formatHhmmss(seconds)
    %FORMATHHMMSS Format seconds as HH:MM:SS, truncating and clamping to zero.
    %   Hours are not wrapped at 24, and NaN reads as 00:00:00.

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
    %   Each digit followed by a whole number of trailing digit triples gains
    %   a comma, which leaves a leading sign, NaN and Inf untouched.

    text = regexprep(sprintf('%.0f', value), '\d(?=(\d{3})+$)', '$0,');
end
