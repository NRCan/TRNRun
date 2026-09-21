using System.Text.Json.Serialization;

namespace TRNRun.Internal;

/// <summary>One queue request, matching the native stdin schema.</summary>
/// <param name="RunId">Non-empty identifier the queue attaches to every event for this run.</param>
/// <param name="DeckFile">Full deck path; the queue validates existence and extension.</param>
/// <param name="RunnerPath">Full path to the runner executable used for this request.</param>
/// <param name="RunnerArgs">Arguments forwarded to the runner.</param>
internal sealed record QueueRequest(
    [property: JsonPropertyName("runID")] string RunId,
    [property: JsonPropertyName("deckFile")] string DeckFile,
    [property: JsonPropertyName("runnerPath")] string RunnerPath,
    [property: JsonPropertyName("runnerArgs")] string[] RunnerArgs);

/// <summary>Serializes queue requests without reflection, keeping the library trim- and AOT-safe.</summary>
[JsonSerializable(typeof(QueueRequest))]
internal sealed partial class QueueJsonContext : JsonSerializerContext;
