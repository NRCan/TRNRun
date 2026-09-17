using System.Text.Json;

namespace TRNRun.Internal;

// Parses routed native JSON Lines events; never touches simulation state.
internal static class EventParser
{
    /// <summary>Parses one queue output line into a typed event.</summary>
    /// <param name="line">A single line read from queue standard output.</param>
    /// <returns>
    /// The parsed event, or <see langword="null"/> when the line is blank, is not valid JSON,
    /// or does not contain string-valued <c>runID</c> and <c>kind</c> routing fields.
    /// </returns>
    /// <exception cref="JsonException">
    /// A routed event has an unknown kind or contains a missing or invalid field.
    /// </exception>
    /// <remarks>
    /// Event kinds are matched case-insensitively. Native status, severity, and timestamp strings
    /// are preserved unchanged so future values remain available to callers.
    /// </remarks>
    internal static TrnRunEvent? Parse(string line)
    {
        if (string.IsNullOrWhiteSpace(line))
        {
            return null;
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(line);
        }
        catch (JsonException)
        {
            return null; // Non-JSON diagnostic output.
        }

        // The try covers only JsonDocument.Parse: field errors from ParseRouted must surface.
        using (document)
        {
            JsonElement data = document.RootElement;
            if (data.ValueKind != JsonValueKind.Object
                || !IsString(data, "runID")
                || !IsString(data, "kind"))
            {
                return null;
            }

            return ParseRouted(data);
        }
    }

    private static bool IsString(JsonElement data, string name) =>
        data.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String;

    // Past this point the line is ours, so an unexpected shape is a native contract violation.
    private static TrnRunEvent ParseRouted(JsonElement data)
    {
        string kind = RequireString(data, "kind").ToUpperInvariant();

        return kind switch
        {
            "STATUS" => ParseStatus(data),
            "PROGRESS" => ParseProgress(data),
            "CONFIG" => ParseConfig(data),
            "SETTING" => ParseSetting(data),
            "LOG" => ParseLog(data),
            "QUEUE" => ParseQueue(data),
            _ => throw new JsonException($"Unknown event kind '{kind}'."),
        };
    }

    private static StatusEvent ParseStatus(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Status: RequireString(data, "status"),
            Message: OptionalString(data, "message") ?? string.Empty
        );

    private static ProgressEvent ParseProgress(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Time: RequireDouble(data, "time"),
            Percent: RequireDouble(data, "percent"),
            Elapsed: RequireDouble(data, "elapsed"),
            Eta: RequireDouble(data, "eta")
        );

    private static ConfigEvent ParseConfig(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Start: RequireDouble(data, "start"),
            Stop: RequireDouble(data, "stop"),
            Step: RequireDouble(data, "step")
        );

    private static SettingEvent ParseSetting(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            TrnExePath: RequireString(data, "trnexePath"),
            GuiVisibility: RequireString(data, "guiVisibility"),
            WaitForGui: RequireBoolean(data, "waitForGui"),
            WaitForLst: RequireBoolean(data, "waitForLst"),
            WaitForTmp: RequireBoolean(data, "waitForTmp"),
            DetectTimeoutMs: RequireInt64(data, "detectTimeoutMs"),
            ExtraDelayMs: RequireInt64(data, "extraDelayMs"),
            WatchLog: RequireBoolean(data, "watchLog"),
            WatchTmp: RequireBoolean(data, "watchTmp"),
            WatchTimeoutMs: RequireInt64(data, "watchTimeoutMs"),
            StallTimeoutMs: RequireInt64(data, "stallTimeoutMs"),
            PollMs: RequireInt64(data, "pollMs"),
            CleanOnSuccess: RequireBoolean(data, "cleanOnSuccess"),
            KillOnTimeout: RequireBoolean(data, "killOnTimeout"),
            KillOnStall: RequireBoolean(data, "killOnStall"),
            Severity: RequireString(data, "severity"),
            WriteEvents: RequireBoolean(data, "writeEvents")
        );

    private static LogEvent ParseLog(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Severity: RequireString(data, "severity"),
            Time: OptionalDouble(data, "time"),
            UnitId: OptionalInt64(data, "unitID"),
            TypeId: OptionalInt64(data, "typeID"),
            MessageCode: OptionalInt64(data, "messageCode"),
            Message: OptionalString(data, "message"),
            Information: OptionalString(data, "information")
        );

    private static QueueEvent ParseQueue(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Status: RequireString(data, "event"),
            ExitCode: OptionalInt32(data, "exitCode")
        );

    private static JsonElement Require(JsonElement data, string name, JsonValueKind kind, string expected) =>
        data.TryGetProperty(name, out JsonElement value) && value.ValueKind == kind
            ? value
            : throw Invalid(name, expected);

    private static string RequireString(JsonElement data, string name) =>
        Require(data, name, JsonValueKind.String, "a string").GetString()!;

    private static bool RequireBoolean(JsonElement data, string name) =>
        data.TryGetProperty(name, out JsonElement value)
        && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : throw Invalid(name, "a boolean");

    private static double RequireDouble(JsonElement data, string name)
    {
        const string Expected = "a finite number";

        return Require(data, name, JsonValueKind.Number, Expected).TryGetDouble(out double number)
            && double.IsFinite(number)
                ? number
                : throw Invalid(name, Expected);
    }

    private static int RequireInt32(JsonElement data, string name)
    {
        const string Expected = "a 32-bit integer";

        return Require(data, name, JsonValueKind.Number, Expected).TryGetInt32(out int number)
            ? number
            : throw Invalid(name, Expected);
    }

    private static long RequireInt64(JsonElement data, string name)
    {
        const string Expected = "a 64-bit integer";

        return Require(data, name, JsonValueKind.Number, Expected).TryGetInt64(out long number)
            ? number
            : throw Invalid(name, Expected);
    }

    private static JsonException Invalid(string name, string expected) =>
        new($"Field '{name}' must be {expected}.");

    // Absent and JSON null are both "not reported"; anything else still has to be well formed.
    private static bool IsNullOrMissing(JsonElement data, string name) =>
        !data.TryGetProperty(name, out JsonElement value) || value.ValueKind == JsonValueKind.Null;

    private static string? OptionalString(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireString(data, name);

    private static double? OptionalDouble(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireDouble(data, name);

    private static int? OptionalInt32(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireInt32(data, name);

    private static long? OptionalInt64(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireInt64(data, name);
}
