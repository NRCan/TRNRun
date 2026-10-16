using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace TRNRun.Internal;

/// <summary>Parses trnrund's database rows into typed records.</summary>
/// <remarks>
/// The daemon flattens the latest TRNRun event of each kind into its run's row.
/// <see cref="ParseRun"/> groups those columns back into the events they came from, and
/// <see cref="ParseLog"/> reads one <c>logs</c> row as a <see cref="LogEvent"/>. Anything the
/// daemon saved that this package cannot read raises <see cref="InvalidDataException"/>,
/// rather than being misreported.
/// </remarks>
internal static class RowParser
{
    /// <summary>Parses a <c>runs</c> row; an event TRNRun has not reported yet becomes <see langword="null"/>.</summary>
    /// <exception cref="InvalidDataException">The row holds a value this package does not know.</exception>
    internal static SimulationInfo ParseRun(DatabaseRow row)
    {
        long runId = Required(row.GetInt64("run_id"), "run_id");
        string? status = row.GetString("trnrun_status");
        double? percent = row.GetDouble("percent");
        double? stop = row.GetDouble("stop_time");
        string? setting = row.GetString("setting");
        return new SimulationInfo
        {
            RunId = runId,
            State = ParseState(Required(row.GetString("state"), "state")),
            SessionId = Required(row.GetInt64("session_id"), "session_id"),
            Label = row.GetString("label"),
            Revision = Required(row.GetInt64("revision"), "revision"),
            DeckFile = Required(row.GetString("deck_file"), "deck_file"),
            TrnrunArgs = ParseArgs(Required(row.GetString("trnrun_args"), "trnrun_args"), runId),
            Status = status is null ? null : new StatusEvent(ParseStatus(status), row.GetString("trnrun_message") ?? ""),
            Progress = percent is null
                ? null
                : new ProgressEvent(
                    Required(row.GetDouble("sim_time"), "sim_time"),
                    percent.Value,
                    Required(row.GetDouble("elapsed_ms"), "elapsed_ms"),
                    Required(row.GetDouble("eta_ms"), "eta_ms")),
            Config = stop is null
                ? null
                : new ConfigEvent(
                    Required(row.GetDouble("start_time"), "start_time"),
                    stop.Value,
                    Required(row.GetDouble("time_step"), "time_step")),
            Setting = setting is null ? null : ParseSetting(setting, runId),
            Notices = (int)Required(row.GetInt64("notices"), "notices"),
            Warnings = (int)Required(row.GetInt64("warnings"), "warnings"),
            Fatals = (int)Required(row.GetInt64("fatals"), "fatals"),
            Succeeded = row.GetInt64("succeeded") is { } succeeded && succeeded != 0,
            ExitCode = row.GetInt64("exit_code") is { } exitCode ? (int)exitCode : null,
            Error = row.GetString("error") ?? "",
            SubmittedAt = ParseTimestamp(row.GetString("submitted_at")),
            StartedAt = ParseTimestamp(row.GetString("started_at")),
            FinishedAt = ParseTimestamp(row.GetString("finished_at")),
        };
    }

    /// <summary>Parses a <c>logs</c> row.</summary>
    internal static LogEvent ParseLog(DatabaseRow row) => new(
        LogId: Required(row.GetInt64("log_id"), "log_id"),
        RunId: Required(row.GetInt64("run_id"), "run_id"),
        Severity: Required(row.GetString("severity"), "severity"),
        Time: Required(row.GetDouble("sim_time"), "sim_time"),
        UnitId: row.GetInt64("unit_id"),
        TypeId: row.GetInt64("type_id"),
        MessageCode: row.GetInt64("message_code"),
        Message: row.GetString("message"),
        Information: row.GetString("information"));

    /// <summary>Returns the name trnrund saves for a state, such as <c>QUEUED</c>.</summary>
    internal static string StateName(SimulationState state) => state switch
    {
        SimulationState.Queued => "QUEUED",
        SimulationState.Running => "RUNNING",
        SimulationState.Finished => "FINISHED",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, "Unknown simulation state."),
    };

    /// <summary>Parses a saved state name.</summary>
    /// <exception cref="InvalidDataException">The name is not one of trnrund's states.</exception>
    internal static SimulationState ParseState(string name) => name switch
    {
        "QUEUED" => SimulationState.Queued,
        "RUNNING" => SimulationState.Running,
        "FINISHED" => SimulationState.Finished,
        _ => throw new InvalidDataException($"Unknown run state '{name}'."),
    };

    /// <summary>Parses a STATUS name as TRNRun writes it, such as <c>DONE</c>.</summary>
    /// <exception cref="InvalidDataException">The name is not one of TRNRun's statuses.</exception>
    internal static SimulationStatus ParseStatus(string name) => name switch
    {
        "PENDING" => SimulationStatus.Pending,
        "LAUNCHING" => SimulationStatus.Launching,
        "RUNNING" => SimulationStatus.Running,
        "DONE" => SimulationStatus.Done,
        "CANCELLED" => SimulationStatus.Cancelled,
        "ERROR" => SimulationStatus.Error,
        "TIMEOUT" => SimulationStatus.Timeout,
        "STALLED" => SimulationStatus.Stalled,
        _ => throw new InvalidDataException($"Unknown TRNRun status '{name}'."),
    };

    /// <summary>Parses a saved UTC timestamp, such as <c>2026-10-09T14:03:12.345Z</c>.</summary>
    internal static DateTimeOffset? ParseTimestamp(string? value) =>
        value is null
            ? null
            : DateTimeOffset.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

    /// <summary>Parses the saved <c>trnrun_args</c> JSON array.</summary>
    private static string[] ParseArgs(string text, long runId)
    {
        try
        {
            return JsonSerializer.Deserialize(text, RowJsonContext.Default.StringArray)
                ?? throw new InvalidDataException($"Run {runId} has null trnrun_args.");
        }
        catch (JsonException error)
        {
            throw new InvalidDataException($"Unreadable trnrun_args of run {runId}: {error.Message}", error);
        }
    }

    /// <summary>Parses the saved SETTING JSON, whose camelCase keys must be exactly <see cref="SettingEvent"/>'s.</summary>
    private static SettingEvent ParseSetting(string text, long runId)
    {
        try
        {
            return JsonSerializer.Deserialize(text, RowJsonContext.Default.SettingEvent)
                ?? throw new InvalidDataException($"Run {runId} has a null setting.");
        }
        catch (JsonException error)
        {
            throw new InvalidDataException($"Unreadable setting of run {runId}: {error.Message}", error);
        }
    }

    /// <summary>Returns a column that trnrund never leaves NULL.</summary>
    private static T Required<T>(T? value, string column)
        where T : struct =>
        value ?? throw new InvalidDataException($"Column '{column}' is unexpectedly NULL.");

    /// <summary>Returns a text column that trnrund never leaves NULL.</summary>
    private static string Required(string? value, string column) =>
        value ?? throw new InvalidDataException($"Column '{column}' is unexpectedly NULL.");
}

/// <summary>Reads saved JSON without reflection, keeping the library trim- and AOT-safe.</summary>
/// <remarks>A SETTING with a missing or unknown key is rejected, never silently defaulted or dropped.</remarks>
[JsonSourceGenerationOptions(
    PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
    RespectRequiredConstructorParameters = true,
    RespectNullableAnnotations = true)]
[JsonSerializable(typeof(SettingEvent))]
[JsonSerializable(typeof(string[]))]
internal sealed partial class RowJsonContext : JsonSerializerContext;
