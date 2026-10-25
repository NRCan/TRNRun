using System.Text.Json;
using System.Text.Json.Serialization;

namespace TRNRun;

/// <summary>One simulation as trnrund last reported it; a property is <see langword="null"/> where TRNRun has not reported it yet.</summary>
/// <remarks>A snapshot: ask <see cref="Daemon.SimulationAsync"/> again for its current state.</remarks>
public sealed record Simulation
{
    /// <summary>ID the daemon assigned; never reused.</summary>
    public required long SimId { get; init; }

    /// <summary>Daemon lifecycle.</summary>
    public required SimulationState State { get; init; }

    /// <summary>Absolute deck path.</summary>
    public required string DeckFile { get; init; }

    /// <summary>Label it was added with.</summary>
    public string? Label { get; init; }

    /// <summary>TRNRun options it was added with.</summary>
    public IReadOnlyList<string> TrnrunArgs { get; init; } = [];

    /// <summary>TRNRun's latest status; can be <see cref="SimulationStatus.Done"/> before <see cref="State"/> is <see cref="SimulationState.Finished"/>.</summary>
    [JsonPropertyName("trnrunStatus")]
    public SimulationStatus? Status { get; init; }

    /// <summary>Detail of <see cref="Status"/>.</summary>
    [JsonPropertyName("trnrunMessage")]
    public string? StatusMessage { get; init; }

    /// <summary>Latest simulation time, in simulated hours.</summary>
    public double? SimTime { get; init; }

    /// <summary>Completion, from 0 to 1.</summary>
    public double? Percent { get; init; }

    /// <summary>Wall-clock milliseconds since TRNSYS started.</summary>
    public double? ElapsedMs { get; init; }

    /// <summary>Estimated wall-clock milliseconds remaining.</summary>
    public double? EtaMs { get; init; }

    /// <summary>The deck's start, in simulated hours.</summary>
    public double? StartTime { get; init; }

    /// <summary>The deck's stop, in simulated hours.</summary>
    public double? StopTime { get; init; }

    /// <summary>The deck's time step, in simulated hours.</summary>
    public double? TimeStep { get; init; }

    /// <summary>Settings TRNRun applied, its defaults included, keyed by TRNRun's camelCase names.</summary>
    public JsonElement? Setting { get; init; }

    /// <summary>Notice log entries so far.</summary>
    public int Notices { get; init; }

    /// <summary>Warning log entries so far.</summary>
    public int Warnings { get; init; }

    /// <summary>Fatal log entries so far.</summary>
    public int Fatals { get; init; }

    /// <summary>Log entries, oldest first; empty unless asked for with <c>withLogs</c>.</summary>
    public IReadOnlyList<LogEvent> Logs { get; init => field = value ?? []; } = []; // The JSON source generator sets an absent key to null.

    /// <summary>Whether it finished with <see cref="SimulationStatus.Done"/>, exit code 0 and no <see cref="Error"/>.</summary>
    public bool? Succeeded { get; init; }

    /// <summary>TRNRun's exit code; <see langword="null"/> if cancelled or never started.</summary>
    public int? ExitCode { get; init; }

    /// <summary>Why the daemon failed or cancelled it.</summary>
    public string? Error { get; init; }

    /// <summary>When it was added.</summary>
    public DateTimeOffset? SubmittedAt { get; init; }

    /// <summary>When TRNRun started; <see langword="null"/> for one that never started.</summary>
    public DateTimeOffset? StartedAt { get; init; }

    /// <summary>When it finished.</summary>
    public DateTimeOffset? FinishedAt { get; init; }
}
