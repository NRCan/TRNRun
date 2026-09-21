using System.Text.Json;

namespace TRNRun.Internal;

internal static class EventParser
{
<<<<<<< HEAD
    /// <summary>Parses one queue output line into a typed event.</summary>
    /// <param name="line">One line from queue standard output.</param>
    /// <returns>
    /// The parsed event, or null for blank, invalid JSON, or unrouted lines
    /// lacking string-valued runID and kind fields.
    /// </returns>
    /// <exception cref="JsonException">
    /// A routed event has an unknown kind or a missing or invalid field.
    /// </exception>
    /// <remarks>Kind matching is case-insensitive; native status, severity, and timestamp strings are preserved.</remarks>
=======
    /// <summary>Parses one queue output line into an event.</summary>
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
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

            if (
                data.ValueKind != JsonValueKind.Object
                || !IsString(data, "runID")
                || !IsString(data, "kind")
            )
            {
                return null;
            }

            return ParseRouted(data);
        }
    }

    /// <summary>Checks whether a field contains a JSON string.</summary>
    private static bool IsString(JsonElement data, string name) =>
        data.TryGetProperty(name, out JsonElement value)
        && value.ValueKind == JsonValueKind.String;

    /// <summary>Parses a routed event according to its kind.</summary>
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

    /// <summary>Parses a runner status event.</summary>
    private static StatusEvent ParseStatus(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Status: RequireStatus(data, "status"),
            Message: OptionalString(data, "message") ?? string.Empty
        );

    /// <summary>Parses a simulation progress event.</summary>
    private static ProgressEvent ParseProgress(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Time: RequireDouble(data, "time"),
            Percent: RequireDouble(data, "percent"),
            Elapsed: RequireDouble(data, "elapsed"),
            Eta: RequireDouble(data, "eta")
        );

    /// <summary>Parses a simulation configuration event.</summary>
    private static ConfigEvent ParseConfig(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Start: RequireDouble(data, "start"),
            Stop: RequireDouble(data, "stop"),
            Step: RequireDouble(data, "step")
        );

    /// <summary>Parses an effective runner settings event.</summary>
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

    /// <summary>Parses a TRNSYS log event.</summary>
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

    /// <summary>Parses a queue lifecycle event.</summary>
    private static QueueEvent ParseQueue(JsonElement data) =>
        new(
            RunId: RequireString(data, "runID"),
            Timestamp: RequireString(data, "timestamp"),
            Status: RequireString(data, "event"),
            ExitCode: OptionalInt32(data, "exitCode")
        );

<<<<<<< HEAD
    /// <summary>Requires a field of the given JSON kind.</summary>
    private static JsonElement Require(
        JsonElement data,
        string name,
        JsonValueKind kind,
        string expected
    ) =>
=======
    /// <summary>Gets a required field of the specified JSON kind.</summary>
    private static JsonElement Require(JsonElement data, string name, JsonValueKind kind, string expected) =>
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
        data.TryGetProperty(name, out JsonElement value) && value.ValueKind == kind
            ? value
            : throw Invalid(name, expected);

    /// <summary>Gets a required JSON string.</summary>
    private static string RequireString(JsonElement data, string name) =>
        Require(data, name, JsonValueKind.String, "a string").GetString()!;

    /// <summary>Gets a required simulation status.</summary>
    private static SimulationStatus RequireStatus(JsonElement data, string name)
    {
        string value = RequireString(data, name);

        return value switch
        {
            "PENDING" => SimulationStatus.Pending,
            "LAUNCHING" => SimulationStatus.Launching,
            "RUNNING" => SimulationStatus.Running,
            "DONE" => SimulationStatus.Done,
            "CANCELLED" => SimulationStatus.Cancelled,
            "ERROR" => SimulationStatus.Error,
            "TIMEOUT" => SimulationStatus.Timeout,
            "STALLED" => SimulationStatus.Stalled,
            _ => throw new JsonException($"Unknown simulation status '{value}'."),
        };
    }

    /// <summary>Gets a required JSON Boolean.</summary>
    private static bool RequireBoolean(JsonElement data, string name) =>
        data.TryGetProperty(name, out JsonElement value)
        && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            ? value.GetBoolean()
            : throw Invalid(name, "a boolean");

    /// <summary>Gets a required finite JSON number.</summary>
    private static double RequireDouble(JsonElement data, string name)
    {
        const string Expected = "a finite number";

        return Require(data, name, JsonValueKind.Number, Expected)
                .TryGetDouble(out double number)
            && double.IsFinite(number)
                ? number
                : throw Invalid(name, Expected);
    }

    /// <summary>Gets a required 32-bit JSON integer.</summary>
    private static int RequireInt32(JsonElement data, string name)
    {
        const string Expected = "a 32-bit integer";

        return Require(data, name, JsonValueKind.Number, Expected)
            .TryGetInt32(out int number)
                ? number
                : throw Invalid(name, Expected);
    }

    /// <summary>Gets a required 64-bit JSON integer.</summary>
    private static long RequireInt64(JsonElement data, string name)
    {
        const string Expected = "a 64-bit integer";

        return Require(data, name, JsonValueKind.Number, Expected)
            .TryGetInt64(out long number)
                ? number
                : throw Invalid(name, Expected);
    }

<<<<<<< HEAD
    /// <summary>Reads a string, or null for an absent or JSON-null field.</summary>
=======
    /// <summary>Creates an exception for an invalid field.</summary>
    private static JsonException Invalid(string name, string expected) =>
        new($"Field '{name}' must be {expected}.");

    /// <summary>Checks whether a field is absent or null.</summary>
    private static bool IsNullOrMissing(JsonElement data, string name) =>
        !data.TryGetProperty(name, out JsonElement value) || value.ValueKind == JsonValueKind.Null;

    /// <summary>Gets an optional JSON string.</summary>
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
    private static string? OptionalString(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireString(data, name);

    /// <summary>Gets an optional finite JSON number.</summary>
    private static double? OptionalDouble(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireDouble(data, name);

    /// <summary>Gets an optional 32-bit JSON integer.</summary>
    private static int? OptionalInt32(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireInt32(data, name);

    /// <summary>Gets an optional 64-bit JSON integer.</summary>
    private static long? OptionalInt64(JsonElement data, string name) =>
        IsNullOrMissing(data, name) ? null : RequireInt64(data, name);

    /// <summary>Checks for an absent or JSON-null field.</summary>
    private static bool IsNullOrMissing(JsonElement data, string name) =>
        !data.TryGetProperty(name, out JsonElement value)
        || value.ValueKind == JsonValueKind.Null;

    /// <summary>Reports a field's expected type.</summary>
    private static JsonException Invalid(string name, string expected) =>
        new($"Field '{name}' must be {expected}.");
}
