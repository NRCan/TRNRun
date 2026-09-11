classdef Display < handle
    %DISPLAY Throttled plain-text Command Window simulation summary.

    properties (Access = private)
        enabled_ = true
        refresh_interval_ = 1
        last_refresh_
        active_
        active_ids_ = {}
    end

    methods
        function obj = Display(refresh_interval)
            refresh_interval = trnrun.internal.requireFiniteScalar( ...
                refresh_interval, 'refresh_interval');
            obj.enabled_ = refresh_interval > 0;
            obj.refresh_interval_ = refresh_interval;
            obj.last_refresh_ = tic;
            obj.active_ = containers.Map('KeyType', 'char', 'ValueType', 'any');
        end

        function simulation_started(obj, simulation)
            if ~obj.enabled_
                return
            end
            key = sprintf('%.0f', simulation.id);
            if ~isKey(obj.active_, key)
                obj.active_(key) = simulation;
                obj.active_ids_{end + 1} = key;
            end
            obj.refresh(true);
        end

        function simulation_finished(obj, simulation)
            if ~obj.enabled_
                return
            end
            key = sprintf('%.0f', simulation.id);
            if isKey(obj.active_, key)
                remove(obj.active_, key);
                obj.active_ids_(strcmp(obj.active_ids_, key)) = [];
            end
            fprintf('%s\n', obj.render_line(simulation));
            obj.last_refresh_ = tic;
        end

        function refresh(obj, force)
            if nargin < 2
                force = false;
            end
            if ~obj.enabled_ || (~force && toc(obj.last_refresh_) < obj.refresh_interval_)
                return
            end
            for index = 1:numel(obj.active_ids_)
                key = obj.active_ids_{index};
                if isKey(obj.active_, key)
                    fprintf('%s\n', obj.render_line(obj.active_(key)));
                end
            end
            obj.last_refresh_ = tic;
        end
    end

    methods (Access = private)
        function line = render_line(~, simulation)
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
                elapsed = format_hhmmss(simulation.progress.elapsed / 1000);
                eta = format_hhmmss(simulation.progress.eta / 1000);
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

function text = format_hhmmss(seconds)
seconds = max(fix(seconds), 0);
hours = fix(seconds / 3600);
seconds = seconds - hours * 3600;
minutes = fix(seconds / 60);
seconds = seconds - minutes * 60;
text = sprintf('%02d:%02d:%02d', hours, minutes, seconds);
end
