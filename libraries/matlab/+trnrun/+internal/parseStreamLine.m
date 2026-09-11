function [runID, event] = parseStreamLine(line, mode)
    %PARSESTREAMLINE Parse and validate one queue stdout line.
    %   [RUNID, EVENT] = PARSESTREAMLINE(LINE) accepts a character row vector or
    %   nonmissing string scalar. Diagnostics and JSON without valid routing
    %   fields return [] for both outputs. Routable malformed events raise
    %   trnrun:EventParseError.
    %
    %   PARSESTREAMLINE(LINE, "event") enables strict single-event parsing.
    %   LINE may be JSON text or a decoded scalar struct. Invalid input raises
    %   trnrun:EventParseError instead of being treated as a diagnostic.
    %   The default mode is "stream".
    %
    %   RUNID is a character vector. EVENT uses wire-format field names and
    %   string scalars for text. All event kinds require runID; only QUEUE
    %   requires event. Optional numbers default to NaN and optional text to
    %   string(missing), except STATUS.message, which defaults to "".

    if nargin < 2
        mode = "stream";
    end
    if ~isText(mode) || ~any(strcmp(mode, {'stream', 'event'}))
        parseError('mode must be ''event'' or ''stream''');
    end

    if strcmp(mode, 'event')
        event = parseEvent(line);
        runID = char(event.runID);
        return
    end

    runID = [];
    event = [];

    if ~isText(line)
        return
    end

    try
        data = jsondecode(char(line));
    catch
        return
    end

    % Only routable objects are events; other stdout belongs to diagnostics.
    if ~isstruct(data) || ~isscalar(data) || ...
            ~isfield(data, 'runID') || ~isfield(data, 'kind') || ...
            ~isText(data.runID) || ~isText(data.kind)
        return
    end

    % Keep validation outside the decode catch so malformed events surface.
    event = parseEventData(data);
    runID = char(event.runID);
end

function event = parseEvent(line)
    %PARSEEVENT Decode one event, reporting invalid input as a parse error.
    if isstruct(line)
        data = line;
    else
        if ~isText(line)
            parseError('event line must be a string scalar or character vector');
        end

        try
            data = jsondecode(char(line));
        catch exception
            parseError('invalid JSON: %s', exception.message);
        end
    end

    event = parseEventData(data);
end

function event = parseEventData(data)
    %PARSEEVENTDATA Validate a decoded object and dispatch to its event parser.
    %   Each kind has a fixed field order and scalar values, allowing same-kind
    %   events to concatenate without losing missing entries in field arrays.
    if ~isstruct(data) || ~isscalar(data)
        parseError('event must be a JSON object');
    end

    kind = upper(requireStr(data, 'kind'));
    switch kind
        case "STATUS"
            event = parseStatus(data);
        case "PROGRESS"
            event = parseProgress(data);
        case "CONFIG"
            event = parseConfig(data);
        case "SETTING"
            event = parseSetting(data);
        case "LOG"
            event = parseLog(data);
        case "QUEUE"
            event = parseQueue(data);
        otherwise
            parseError('unknown event kind ''%s''', kind);
    end
end

function event = parseStatus(data)
    %PARSESTATUS Build a validated STATUS event with an optional message.
    event = struct( ...
        'kind', "STATUS", ...
        'runID', requireStr(data, 'runID'), ...
        'status', requireStr(data, 'status'), ...
        'timestamp', requireStr(data, 'timestamp'), ...
        'message', optionalStr(data, 'message', ""));
end

function event = parseProgress(data)
    %PARSEPROGRESS Build a validated PROGRESS event with timing and completion data.
    event = struct( ...
        'kind', "PROGRESS", ...
        'runID', requireStr(data, 'runID'), ...
        'time', requireFloat(data, 'time'), ...
        'percent', requireFloat(data, 'percent'), ...
        'elapsed', requireFloat(data, 'elapsed'), ...
        'eta', requireFloat(data, 'eta'), ...
        'timestamp', requireStr(data, 'timestamp'));
end

function event = parseConfig(data)
    %PARSECONFIG Build a validated CONFIG event with simulation time bounds.
    event = struct( ...
        'kind', "CONFIG", ...
        'runID', requireStr(data, 'runID'), ...
        'start', requireFloat(data, 'start'), ...
        'stop', requireFloat(data, 'stop'), ...
        'step', requireFloat(data, 'step'), ...
        'timestamp', requireStr(data, 'timestamp'));
end

function event = parseSetting(data)
    %PARSESETTING Build a validated SETTING event with runner configuration.
    event = struct( ...
        'kind', "SETTING", ...
        'runID', requireStr(data, 'runID'), ...
        'timestamp', requireStr(data, 'timestamp'), ...
        'trnexePath', requireStr(data, 'trnexePath'), ...
        'guiVisibility', requireStr(data, 'guiVisibility'), ...
        'waitForGui', requireBool(data, 'waitForGui'), ...
        'waitForLst', requireBool(data, 'waitForLst'), ...
        'waitForTmp', requireBool(data, 'waitForTmp'), ...
        'detectTimeoutMs', requireInt(data, 'detectTimeoutMs'), ...
        'extraDelayMs', requireInt(data, 'extraDelayMs'), ...
        'watchLog', requireBool(data, 'watchLog'), ...
        'watchTmp', requireBool(data, 'watchTmp'), ...
        'watchTimeoutMs', requireInt(data, 'watchTimeoutMs'), ...
        'stallTimeoutMs', requireInt(data, 'stallTimeoutMs'), ...
        'pollMs', requireInt(data, 'pollMs'), ...
        'cleanOnSuccess', requireBool(data, 'cleanOnSuccess'), ...
        'killOnTimeout', requireBool(data, 'killOnTimeout'), ...
        'killOnStall', requireBool(data, 'killOnStall'), ...
        'severity', requireStr(data, 'severity'), ...
        'writeEvents', requireBool(data, 'writeEvents'));
end

function event = parseLog(data)
    %PARSELOG Build a validated LOG event with defaults for optional details.
    event = struct( ...
        'kind', "LOG", ...
        'runID', requireStr(data, 'runID'), ...
        'severity', requireStr(data, 'severity'), ...
        'timestamp', requireStr(data, 'timestamp'), ...
        'time', optionalFloat(data, 'time'), ...
        'unitID', optionalInt(data, 'unitID'), ...
        'typeID', optionalInt(data, 'typeID'), ...
        'messageCode', optionalInt(data, 'messageCode'), ...
        'message', optionalStr(data, 'message'), ...
        'information', optionalStr(data, 'information'));
end

function event = parseQueue(data)
    %PARSEQUEUE Build a validated QUEUE event with an optional exit code.
    event = struct( ...
        'kind', "QUEUE", ...
        'event', requireStr(data, 'event'), ...
        'runID', requireStr(data, 'runID'), ...
        'timestamp', requireStr(data, 'timestamp'), ...
        'exitCode', optionalInt(data, 'exitCode'));
end

function value = requireStr(data, key)
    %REQUIRESTR Read a required text field as a nonmissing string scalar.
    value = rawField(data, key);
    % JSON empty strings decode to '', which is not a row vector.
    if ischar(value) && (isrow(value) || isequal(value, ''))
        value = string(value);
    end
    if ~isstring(value) || ~isscalar(value) || ismissing(value)
        parseError('field ''%s'' must be a string', key);
    end
end

function value = optionalStr(data, key, default)
    %OPTIONALSTR Read text or use DEFAULT, which is string(missing) if omitted.
    if nargin < 3
        default = string(missing);
    end
    if isAbsent(data, key)
        value = default;
        return
    end
    value = requireStr(data, key);
end

function value = requireFloat(data, key)
    %REQUIREFLOAT Read a required finite real numeric scalar as a double.
    value = rawField(data, key);
    % ISNUMERIC excludes JSON booleans, which decode as logical values.
    if ~isnumeric(value) || ~isreal(value) || ...
            ~isscalar(value) || ~isfinite(value)
        parseError('field ''%s'' must be a number', key);
    end
    value = double(value);
end

function value = optionalFloat(data, key)
    %OPTIONALFLOAT Read a finite real numeric scalar, or NaN when absent.
    if isAbsent(data, key)
        value = NaN;
        return
    end
    value = requireFloat(data, key);
end

function value = requireInt(data, key)
    %REQUIREINT Read a required finite real integer scalar as a double.
    % JSON numbers decode as doubles; validate integrality, not the class.
    value = requireFloat(data, key);
    if value ~= fix(value)
        parseError('field ''%s'' must be an integer', key);
    end
end

function value = optionalInt(data, key)
    %OPTIONALINT Read a finite real integer scalar, or NaN when absent.
    if isAbsent(data, key)
        value = NaN;
        return
    end
    value = requireInt(data, key);
end

function value = requireBool(data, key)
    %REQUIREBOOL Read a required logical scalar, rejecting numeric 0 and 1.
    value = rawField(data, key);
    if ~islogical(value) || ~isscalar(value)
        parseError('field ''%s'' must be a boolean', key);
    end
end

function value = rawField(data, key)
    %RAWFIELD Return a field without conversion, or [] if the field is missing.
    if isfield(data, key)
        value = data.(key);
    else
        value = [];
    end
end

function tf = isAbsent(data, key)
    %ISABSENT Identify missing fields and empty numeric values as absent.
    % Missing fields and decoded JSON null use []; empty JSON arrays also
    % decode to []. Empty text remains present and is validated as text.
    value = rawField(data, key);
    tf = isnumeric(value) && isempty(value);
end

function tf = isText(value)
    %ISTEXT Accept character row vectors and nonmissing string scalars.
    tf = (ischar(value) && isrow(value)) || ...
        (isstring(value) && isscalar(value) && ~ismissing(value));
end

function parseError(message, varargin)
    %PARSEERROR Raise a formatted error with the shared event-parse identifier.
    throwAsCaller(MException('trnrun:EventParseError', message, varargin{:}));
end
