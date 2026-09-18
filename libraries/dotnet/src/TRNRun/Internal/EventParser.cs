using System.Text.Json;

namespace TRNRun.Internal;

/// <summary>Parses routed native JSON Lines events without modifying simulation state.</summary>
internal static class EventParser
{
    /// <summary>Parses one queue output line into a typed event.</summary>
    /// <param name="line">One line from queue standard output.</param>
    /// <returns>The parsed event, or null for blank, invalid JSON, or unrouted lines lacking string-valued runID and kind fields.</returns>
    /// <exception cref="JsonException">A routed event has an unknown kind or a missing or invalid field.</exception>
    /// <remarks>Kind matching is case-insensitive; native status, severity, and timestamp strings are preserved.</remarks>
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

    /// <summary>Checks for a string-valued field.</summary>
    private static bool IsString(JsonElement data, string name) =>
        data.TryGetProperty(name, out JsonElement value) && value.ValueKind == JsonValueKind.String;

    /// <summary>Dispatches by kind; unknown kinds and invalid fields throw.</summary>
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

    /// <summary>Parses status; a missing or null message becomes empty.</summary>
    private static StatusEvent ParseStatus(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Status: RequireString(data, "status"),
            Message: OptionalString(data, "message") ?? string.Empty
        );

    /// <summary>Parses finite simulation progress and wall-clock timing.</summary>
    private static ProgressEvent ParseProgress(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Time: RequireDouble(data, "time"),
            Percent: RequireDouble(data, "percent"),
            Elapsed: RequireDouble(data, "elapsed"),
            Eta: RequireDouble(data, "eta")
        );

    /// <summary>Parses finite simulation bounds and time step.</summary>
    private static ConfigEvent ParseConfig(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Start: RequireDouble(data, "start"),
            Stop: RequireDouble(data, "stop"),
            Step: RequireDouble(data, "step")
        );

    /// <summary>Parses settings as native strings and integer milliseconds.</summary>
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

    /// <summary>Parses a TRNSYS log entry; missing optional fields stay null.</summary>
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

    /// <summary>Parses queue lifecycle status and an optional runner exit code.</summary>
    private static QueueEvent ParseQueue(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Status: RequireString(data, "event"),
            ExitCode: OptionalInt32(data, "exitCode")
        );

    /// <summary>Requires a field of the given JSON kind.</summary>
    private static JsonElement Require(JsonElement data, string name, JsonValueKind kind, string expected) =>
        data.TryGetProperty(name, out JsonElement value) && value.ValueKind == kind
            ? value
            : throw Invalid(name, expected);

    /// <summary>Reads a required JSON string without coercion.</summary>
    private static string RequireString(JsonElement data, string name) =>
        Require(data, name, JsonValueKind.String, "a string").GetString()!;

    /// <summary>Reads a required JSON Boolean without coercion.</summary>
    private static bool RequireBoolean(JsonElement data, string name) =>
        data.TryGetProperty(name, out JsonElement value)
        && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : throw Invalid(name, "a boolean");

    /// <summary>Reads a required JSON number as a finite double.</summary>
    private static double RequireDouble(JsonElement data, string name)
    {
        const string Expected = "a finite number";

        return Require(data, name, JsonValueKind.Number, Expected).TryGetDouble(out double number)
            && double.IsFinite(number)
                ? number
                : throw Invalid(name, Expected);
    }

    /// <summary>Reads a required 32-bit JSON integer.</summary>
    private static int RequireInt32(JsonElement data, string name)
    {
        const string Expected = "a 32-bit integer";

        return Require(data, name, JsonValueKind.Number, Expected).TryGetInt32(out int number)
            ? number
            : throw Invalid(name, Expected);
    }

    /// <summary>Reads a required 64-bit JSON integer.</summary>
    private static long RequireInt64(JsonElement data, string name)
    {
        const string Expected = "a 64-bit integer";

        return Require(data, name, JsonValueKind.Number, Expected).TryGetInt64(out long number)
            ? number
            : throw Invalid(name, Expected);
    }

    /// <summary>Reports a field's expected type.</summary>
    private static JsonException Invalid(string name, string expected) =>
        new($"Field '{name}' must be {expected}.");

    /// <summary>Checks for an absent or JSON-null field.</summary>
    private static bool IsNullOrMissing(JsonElement data, string name) =>
        !data.TryGetProperty(name, out JsonElement value) || value.ValueKind == JsonValueKind.Null;

    /// <summary>Reads a string, or null for an absent or JSON-null field.</summary>
    private static string? OptionalString(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireString(data, name);

    /// <summary>Reads a finite double, or null for an absent or JSON-null field.</summary>
    private static double? OptionalDouble(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireDouble(data, name);

    /// <summary>Reads a 32-bit integer, or null for an absent or JSON-null field.</summary>
    private static int? OptionalInt32(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireInt32(data, name);

    /// <summary>Reads a 64-bit integer, or null for an absent or JSON-null field.</summary>
    private static long? OptionalInt64(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireInt64(data, name);
}
