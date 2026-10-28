using System.Text.Json;
using System.Text.Json.Serialization;

namespace TRNRun;

/// <summary>One simulation as trnrund reported it; a nullable property is <see langword="null"/> until TRNRun reports it.</summary>
/// <remarks>A snapshot that never updates itself: call <see cref="TRNRunDaemon.GetSimulationAsync"/> again for the current state.</remarks>
public sealed record Simulation
{
    /// <summary>ID trnrund assigned when the deck was added; never reused, even after a release.</summary>
    public required long SimId { get; init; }

    /// <summary>Where trnrund is with it: queued, running or finished.</summary>
    public required SimulationState State { get; init; }

    /// <summary>Absolute path of the deck.</summary>
    public required string DeckFile { get; init; }

    /// <summary>Label given to <see cref="TRNRunDaemon.AddAsync"/>, if any.</summary>
    public string? Label { get; init; }

    /// <summary>TRNRun options the settings became, as a raw JSON object keyed by TRNRun's camelCase option names, such as <c>{"watchTmp":true}</c>.</summary>
    public JsonElement? TrnrunOptions { get; init; }

    /// <summary>TRNRun's latest status; it can already be <see cref="SimulationStatus.Done"/> while <see cref="State"/> is still <see cref="SimulationState.Running"/>, so wait on <see cref="State"/>.</summary>
    [JsonPropertyName("trnrunStatus")]
    public SimulationStatus? Status { get; init; }

    /// <summary>TRNRun's message accompanying <see cref="Status"/>, often empty.</summary>
    [JsonPropertyName("trnrunMessage")]
    public string? StatusMessage { get; init; }

    /// <summary>Simulated time reached so far, in hours; requires <see cref="SimulationSettings.WatchTmp"/>.</summary>
    public double? SimTime { get; init; }

    /// <summary>Completion as a fraction from 0 to 1, not a percentage; requires <see cref="SimulationSettings.WatchTmp"/>.</summary>
    public double? Percent { get; init; }

    /// <summary>Real time since TRNSYS started, as TRNRun last reported it.</summary>
    [JsonPropertyName("elapsedMs")]
    [JsonConverter(typeof(MillisecondsConverter))]
    public TimeSpan? Elapsed { get; init; }

    /// <summary>TRNRun's estimate of the real time remaining.</summary>
    [JsonPropertyName("etaMs")]
    [JsonConverter(typeof(MillisecondsConverter))]
    public TimeSpan? Eta { get; init; }

    /// <summary>Simulation start time from the deck, in hours.</summary>
    public double? StartTime { get; init; }

    /// <summary>Simulation stop time from the deck, in hours.</summary>
    public double? StopTime { get; init; }

    /// <summary>Simulation time step from the deck, in hours.</summary>
    public double? TimeStep { get; init; }

    /// <summary>Every setting TRNRun applied, defaults included, as raw JSON keyed by TRNRun's camelCase option names.</summary>
    public JsonElement? Setting { get; init; }

    /// <summary>Number of notice log entries so far, counted even when <see cref="Logs"/> is empty.</summary>
    public int Notices { get; init; }

    /// <summary>Number of warning log entries so far, counted even when <see cref="Logs"/> is empty.</summary>
    public int Warnings { get; init; }

    /// <summary>Number of fatal log entries so far, counted even when <see cref="Logs"/> is empty.</summary>
    public int Fatals { get; init; }

    /// <summary>Log entries, oldest first; empty unless requested with <c>withLogs</c>.</summary>
    public IReadOnlyList<LogEvent> Logs { get; init => field = value ?? []; } = []; // The JSON source generator assigns null for an absent key, which would replace the [] default.

    /// <summary>Whether it finished with <see cref="SimulationStatus.Done"/>, exit code 0 and no <see cref="Error"/>; <see langword="null"/> until finished.</summary>
    public bool? Succeeded { get; init; }

    /// <summary>TRNRun's exit code; <see langword="null"/> until it exits, and for one cancelled or never started.</summary>
    public int? ExitCode { get; init; }

    /// <summary>Why trnrund failed or cancelled it; <see langword="null"/> otherwise.</summary>
    public string? Error { get; init; }

    /// <summary>When it was added, in UTC.</summary>
    public DateTimeOffset? SubmittedAt { get; init; }

    /// <summary>When TRNRun started, in UTC; <see langword="null"/> while queued and for one that never started.</summary>
    public DateTimeOffset? StartedAt { get; init; }

    /// <summary>When it finished, in UTC; <see langword="null"/> until then.</summary>
    public DateTimeOffset? FinishedAt { get; init; }
}
