using System.Text.Json;

namespace TRNRun;

/// <summary>One run's row in the daemon's database; a property is <see langword="null"/> where its column is NULL.</summary>
public sealed record SimulationInfo
{
    /// <summary>ID the daemon assigned; never reused in its database.</summary>
    public required long RunId { get; init; }

    /// <summary>Daemon lifecycle.</summary>
    public required SimulationState State { get; init; }

    /// <summary>Absolute deck path.</summary>
    public required string DeckFile { get; init; }

    /// <summary>Daemon start that added the run.</summary>
    public required long SessionId { get; init; }

    /// <summary>Tag the run was added with.</summary>
    public string? Label { get; init; }

    /// <summary>Revision of the run's latest save.</summary>
    public required long Revision { get; init; }

    /// <summary>TRNRun options the run was added with.</summary>
    public required IReadOnlyList<string> TrnrunArgs { get; init; }

    /// <summary>TRNRun's latest status; it can report <c>Done</c> before <see cref="State"/> is <c>Finished</c>.</summary>
    public SimulationStatus? Status { get; init; }

    /// <summary>Detail of <see cref="Status"/>.</summary>
    public string? StatusMessage { get; init; }

    /// <summary>Latest progress.</summary>
    public ProgressEvent? Progress { get; init; }

    /// <summary>Simulation start, stop and time step.</summary>
    public ConfigEvent? Config { get; init; }

    /// <summary>Settings TRNRun applied, its defaults included, keyed by camelCase flag name, such as <c>pollMs</c>.</summary>
    public IReadOnlyDictionary<string, JsonElement>? Setting { get; init; }

    /// <summary>Notice log entries saved so far.</summary>
    public required int Notices { get; init; }

    /// <summary>Warning log entries saved so far.</summary>
    public required int Warnings { get; init; }

    /// <summary>Fatal log entries saved so far.</summary>
    public required int Fatals { get; init; }

    /// <summary>Whether it finished with <c>DONE</c>, exit code 0 and no error; <see langword="null"/> until it finishes.</summary>
    public bool? Succeeded { get; init; }

    /// <summary>TRNRun's exit code.</summary>
    public int? ExitCode { get; init; }

    /// <summary>Execution error reported by the daemon.</summary>
    public string? Error { get; init; }

    /// <summary>UTC time the run was added.</summary>
    public required DateTimeOffset SubmittedAt { get; init; }

    /// <summary>UTC time TRNRun started; stays <see langword="null"/> for a run that never started.</summary>
    public DateTimeOffset? StartedAt { get; init; }

    /// <summary>UTC time the run finished.</summary>
    public DateTimeOffset? FinishedAt { get; init; }

    /// <summary>Whether the daemon finished the run; its logs are then complete.</summary>
    public bool IsFinished => State == SimulationState.Finished;
}
