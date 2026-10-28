classdef SimulationSettings
    %SIMULATIONSETTINGS TRNRun options for a simulation.
    %   Each property is the trnrun.exe flag of the same name (see
    %   trnrun.exe --help). An empty property keeps TRNRun's default.
    %
    %   Example:
    %       settings = trnrun.SimulationSettings(watchTmp=true, stallTimeout=60000);

    properties
        % TRNSYS executable; must exist, relative to the current folder.
        trnexePath string {mustBeScalarOrEmpty} = string.empty

        % TRNSYS window: keep, auto, min, minAuto or hidden.
        guiVisibility string {mustBeScalarOrEmpty, ...
            mustBeMember(guiVisibility, ["keep", "auto", "min", "minAuto", "hidden"])} = string.empty

        waitForGui logical {mustBeScalarOrEmpty} = logical.empty
        waitForLst logical {mustBeScalarOrEmpty} = logical.empty
        waitForTmp logical {mustBeScalarOrEmpty} = logical.empty  % requires Type3830

        detectTimeout double {mustBeScalarOrEmpty, mustBeInteger, mustBeNonnegative} = []  % ms; 0 unlimited
        extraDelay    double {mustBeScalarOrEmpty, mustBeInteger, mustBeNonnegative} = []  % ms after launch
        pollMs        double {mustBeScalarOrEmpty, mustBeInteger, mustBePositive}    = []

        watchLog logical {mustBeScalarOrEmpty} = logical.empty
        watchTmp logical {mustBeScalarOrEmpty} = logical.empty  % streams progress; requires Type3830

        % Milliseconds of monitoring; 0 unlimited.
        watchTimeout double {mustBeScalarOrEmpty, mustBeInteger, mustBeNonnegative} = []

        % Milliseconds without progress; 0 disables; requires watchTmp.
        stallTimeout double {mustBeScalarOrEmpty, mustBeInteger, mustBeNonnegative} = []

        clean         logical {mustBeScalarOrEmpty} = logical.empty  % delete .tmp, .log, .lst and .PTI after success
        killOnTimeout logical {mustBeScalarOrEmpty} = logical.empty
        killOnStall   logical {mustBeScalarOrEmpty} = logical.empty

        % Minimum log severity: Notice, Warning or Fatal.
        severity string {mustBeScalarOrEmpty, ...
            mustBeMember(severity, ["Notice", "Warning", "Fatal"])} = string.empty

        writeEvents logical {mustBeScalarOrEmpty} = logical.empty  % mirror events to <deck>.jsonl
    end

    methods
        function obj = SimulationSettings(options)
            %SIMULATIONSETTINGS Create settings from name-value options.

            % Listed explicitly for R2021a; the properties own validation.
            arguments
                options.trnexePath
                options.guiVisibility
                options.waitForGui
                options.waitForLst
                options.waitForTmp
                options.detectTimeout
                options.extraDelay
                options.pollMs
                options.watchLog
                options.watchTmp
                options.watchTimeout
                options.stallTimeout
                options.clean
                options.killOnTimeout
                options.killOnStall
                options.severity
                options.writeEvents
            end

            for name = string(fieldnames(options))'
                obj.(name) = options.(name);
            end
        end

        function options = trnrunOptions(obj)
            %TRNRUNOPTIONS Return trnrund's trnrunOptions: a struct of each set property.

            options = struct();
            for name = string(properties(obj))'
                value = obj.(name);
                if isempty(value)
                    continue
                elseif name == "trnexePath"
                    value = trnrun.internal.resolveFile(value);
                end
                options.(name) = value;
            end
        end
    end
end