classdef SimulationConfig
    %SIMULATIONCONFIG Configure a TRNRun launch.
    %   Value class: each submitted run keeps its own independent copy.
    %
    %   cfg = trnrun.SimulationConfig(watch_tmp=true, stall_timeout_ms=60000)
    %
    %   Except for trnrun_path, each property maps to a runner CLI option.
    %   Text choices are case-insensitive. Detection and watch timeouts of
    %   zero mean unlimited; a zero stall timeout disables stall detection.
    %   Property types and validators apply at construction and assignment.

    properties
        % Runner executable; defaults to the copy bundled with this package.
        trnrun_path (1,1) string {mustBeNonmissing, mustBeNonzeroLengthText} = ...
            fullfile(fileparts(fileparts(mfilename('fullpath'))), "bin", "trnrun.exe")

        % TRNSYS executable (--trnexePath).
        trnexe_path (1,1) string {mustBeNonmissing, mustBeNonzeroLengthText} = ...
            "C:\TRNSYS18\Exe\TrnEXE64.exe"

        % TRNSYS window (--guiVisibility): keep, auto, min, minAuto or hidden.
        gui_visibility (1,1) string {mustBeGuiVisibility} = "hidden"

        wait_for_gui (1,1) logical = true       % --waitForGui
        wait_for_lst (1,1) logical = true       % --waitForLst
        wait_for_tmp (1,1) logical = false      % --waitForTmp; requires Type3830

        detect_timeout_ms (1,1) double {mustBeInteger, mustBeNonnegative} = 300000  % --detectTimeout
        extra_delay_ms    (1,1) double {mustBeInteger, mustBeNonnegative} = 0       % --extraDelay
        poll_ms           (1,1) double {mustBeInteger, mustBePositive}    = 100     % --pollMs

        watch_log (1,1) logical = true          % --watchLog
        watch_tmp (1,1) logical = false         % --watchTmp; requires Type3830
        watch_timeout_ms  (1,1) double {mustBeInteger, mustBeNonnegative} = 0       % --watchTimeout
        stall_timeout_ms  (1,1) double {mustBeInteger, mustBeNonnegative} = 0       % --stallTimeout; requires watch_tmp

        clean_on_success (1,1) logical = false  % --clean
        kill_on_timeout  (1,1) logical = false  % --killOnTimeout
        kill_on_stall    (1,1) logical = false  % --killOnStall

        % Minimum log severity (--severity): Notice, Warning or Fatal.
        severity (1,1) string {mustBeSeverity} = "Notice"

        write_events (1,1) logical = false      % --writeEvents
    end

    methods
        function obj = SimulationConfig(options)
            %SIMULATIONCONFIG Create a configuration from name-value options.
            %   OBJ = trnrun.SimulationConfig() uses the default runner settings.
            %   OBJ = trnrun.SimulationConfig(NAME=VALUE, ...) overrides the
            %   named properties; inputs are converted to the property type.
            %
            %   Before launching, call OBJ = OBJ.validate() to resolve and
            %   check the executable paths.

            % List names explicitly for R2021a; properties own defaults and validation.
            arguments
                options.trnrun_path
                options.trnexe_path
                options.gui_visibility
                options.wait_for_gui
                options.wait_for_lst
                options.wait_for_tmp
                options.detect_timeout_ms
                options.extra_delay_ms
                options.poll_ms
                options.watch_log
                options.watch_tmp
                options.watch_timeout_ms
                options.stall_timeout_ms
                options.clean_on_success
                options.kill_on_timeout
                options.kill_on_stall
                options.severity
                options.write_events
            end

            for name = string(fieldnames(options))'
                obj.(name) = options.(name);
            end
        end

        function obj = validate(obj)
            %VALIDATE Check that the executables exist and make their paths absolute.

            mustBeFile(obj.trnrun_path);
            mustBeFile(obj.trnexe_path);

            [~, info] = fileattrib(obj.trnrun_path);
            obj.trnrun_path = info.Name;
            [~, info] = fileattrib(obj.trnexe_path);
            obj.trnexe_path = info.Name;
        end

        function args = to_cli_args(obj)
            %TO_CLI_ARGS Return unquoted --name:value arguments as a cell row of char vectors.

            args = cellstr([
                "--trnexePath:"    + obj.trnexe_path
                "--guiVisibility:" + obj.gui_visibility
                "--waitForGui:"    + obj.wait_for_gui
                "--waitForLst:"    + obj.wait_for_lst
                "--waitForTmp:"    + obj.wait_for_tmp
                "--detectTimeout:" + sprintf('%.0f', obj.detect_timeout_ms)
                "--extraDelay:"    + sprintf('%.0f', obj.extra_delay_ms)
                "--pollMs:"        + sprintf('%.0f', obj.poll_ms)
                "--watchLog:"      + obj.watch_log
                "--watchTmp:"      + obj.watch_tmp
                "--watchTimeout:"  + sprintf('%.0f', obj.watch_timeout_ms)
                "--stallTimeout:"  + sprintf('%.0f', obj.stall_timeout_ms)
                "--clean:"         + obj.clean_on_success
                "--killOnTimeout:" + obj.kill_on_timeout
                "--killOnStall:"   + obj.kill_on_stall
                "--severity:"      + obj.severity
                "--writeEvents:"   + obj.write_events
            ]');
        end
    end
end

function mustBeGuiVisibility(value)
    %MUSTBEGUIVISIBILITY Accept supported window modes and aliases, ignoring case.

    mustBeMember(lower(value), ["keep", "keepopen", "auto", "autoclose", ...
        "min", "minimized", "minauto", "minimizedauto", "hidden"]);
end

function mustBeSeverity(value)
    %MUSTBESEVERITY Accept supported log severities, ignoring case.

    mustBeMember(lower(value), ["notice", "warning", "fatal"]);
end
