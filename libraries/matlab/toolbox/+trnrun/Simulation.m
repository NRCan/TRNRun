classdef Simulation < handle
    %SIMULATION One simulation as trnrund last reported it.
    %   Properties mirror trnrund's simulation fields. A value TRNRun has not
    %   reported yet is missing, NaN, or NaT.
    %
    %   A trnrun.SimulationManager updates it in place, only during a manager call.

    properties (SetAccess = private)
        simId (1,1) double = NaN               % assigned by trnrund, never reused
        label (1,1) string = missing           % text it was added with
        state (1,1) string = missing           % QUEUED, RUNNING or FINISHED
        deckFile (1,1) string = missing        % absolute deck path
        trnrunArgs (1,:) string = strings(1, 0) % TRNRun flags it was added with
        trnrunStatus (1,1) string = missing    % latest TRNRun status, such as RUNNING or DONE
        trnrunMessage (1,1) string = missing   % detail of trnrunStatus
        percent (1,1) double = NaN             % completion, from 0 to 1
        simTime (1,1) double = NaN             % latest simulation time, in simulated hours
        elapsedMs (1,1) double = NaN           % wall-clock milliseconds since the start
        etaMs (1,1) double = NaN               % estimated wall-clock milliseconds remaining
        startTime (1,1) double = NaN           % deck start, stop and step, in simulated hours
        stopTime (1,1) double = NaN
        timeStep (1,1) double = NaN
        setting = []                           % struct of the settings TRNRun applied
        notices (1,1) double = 0               % log entries so far, by severity
        warnings (1,1) double = 0
        fatals (1,1) double = 0
        logs = []                              % struct array of log entries, oldest first
        succeeded (1,1) logical = false        % finished with DONE, exit code 0 and no error
        exitCode (1,1) double = NaN            % TRNRun's exit code
        error (1,1) string = missing           % why trnrund failed or cancelled it
        submittedAt (1,1) datetime = NaT       % UTC; startedAt stays NaT if it never started
        startedAt (1,1) datetime = NaT
        finishedAt (1,1) datetime = NaT
    end

    methods
        function obj = Simulation(record)
            %SIMULATION Parse a jsondecoded simulation record from trnrund.

            if nargin == 0
                return
            end
            obj.simId = record.simId;
            obj.label = text(record.label);
            obj.state = record.state;
            obj.deckFile = record.deckFile;
            obj.trnrunArgs = reshape(string(record.trnrunArgs), 1, []);
            obj.trnrunStatus = text(record.trnrunStatus);
            obj.trnrunMessage = text(record.trnrunMessage);
            obj.percent = number(record.percent);
            obj.simTime = number(record.simTime);
            obj.elapsedMs = number(record.elapsedMs);
            obj.etaMs = number(record.etaMs);
            obj.startTime = number(record.startTime);
            obj.stopTime = number(record.stopTime);
            obj.timeStep = number(record.timeStep);
            obj.setting = record.setting;
            obj.notices = record.notices;
            obj.warnings = record.warnings;
            obj.fatals = record.fatals;
            if isfield(record, 'logs')
                obj.logs = record.logs;
            end
            obj.succeeded = isequal(record.succeeded, true);
            obj.exitCode = number(record.exitCode);
            obj.error = text(record.error);
            obj.submittedAt = timestamp(record.submittedAt);
            obj.startedAt = timestamp(record.startedAt);
            obj.finishedAt = timestamp(record.finishedAt);
        end
    end

    methods (Access = {?trnrun.SimulationManager, ?matlab.unittest.TestCase})
        function update(obj, latest)
            %UPDATE Copy every property of LATEST, a newer report.

            for name = string(properties(obj))'
                obj.(name) = latest.(name);
            end
        end
    end
end

function value = text(value)
    %TEXT Convert a decoded JSON string, or null, to a string.

    if isnumeric(value)
        value = string(missing);
    end
    value = string(value);
end

function value = number(value)
    %NUMBER Convert a decoded JSON number, or null, to a double.

    if isempty(value)
        value = NaN;
    end
end

function value = timestamp(value)
    %TIMESTAMP Parse a UTC timestamp, or null as NaT.

    if isnumeric(value)
        value = NaT;
        value.TimeZone = 'UTC';
    else
        value = datetime(value, 'InputFormat', 'uuuu-MM-dd''T''HH:mm:ss.SSS''Z''', ...
            'TimeZone', 'UTC');
    end
end
