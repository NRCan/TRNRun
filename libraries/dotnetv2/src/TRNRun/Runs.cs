namespace TRNRun;

/// <summary>Daemon-owned lifecycle, independent of the runner-reported status.</summary>
/// <remarks>
/// <c>Queued → Running → Finished</c>. A run that never starts, such as one cancelled while
/// queued or whose TRNRun cannot launch, goes straight to <see cref="Finished"/>.
/// </remarks>
public enum SimulationState
{
    /// <summary>Saved and waiting for a free slot.</summary>
    Queued,
    /// <summary>TRNRun has started.</summary>
    Running,
    /// <summary>Done, failed or cancelled; the run never changes again.</summary>
    Finished,
}

/// <summary>A run's state at one moment: its row in the daemon's database.</summary>
/// <remarks>Log entries are kept separately; see <see cref="Database.GetLogs"/>.</remarks>
public sealed record SimulationInfo
{
    /// <summary>Number the daemon assigned the run; never reused in its database.</summary>
    public required long RunId { get; init; }

    /// <summary>Daemon lifecycle state.</summary>
    public required SimulationState State { get; init; }

    /// <summary>The daemon start that added the run.</summary>
    public long SessionId { get; init; }

    /// <summary>Tag the run was added with, or <see langword="null"/>.</summary>
    public string? Label { get; init; }

    /// <summary>Revision of the run's latest save.</summary>
    public long Revision { get; init; }

    /// <summary>Absolute deck path.</summary>
    public string DeckFile { get; init; } = "";

    /// <summary>TRNRun options the run was added with.</summary>
    public IReadOnlyList<string> TrnrunArgs { get; init; } = [];

    /// <summary>Latest status, or <see langword="null"/> before TRNRun reports one.</summary>
    public StatusEvent? Status { get; init; }

    /// <summary>Latest progress, or <see langword="null"/> before TRNRun reports one.</summary>
    public ProgressEvent? Progress { get; init; }

    /// <summary>Simulation bounds, or <see langword="null"/> before TRNRun reports them.</summary>
    public ConfigEvent? Config { get; init; }

    /// <summary>Applied settings, or <see langword="null"/> before TRNRun reports them.</summary>
    public SettingEvent? Setting { get; init; }

    /// <summary>Number of Notice log entries saved so far.</summary>
    public int Notices { get; init; }

    /// <summary>Number of Warning log entries saved so far.</summary>
    public int Warnings { get; init; }

    /// <summary>Number of Fatal log entries saved so far.</summary>
    public int Fatals { get; init; }

    /// <summary>Whether the run finished with <c>DONE</c>, exit code 0, and no error; false until it finishes.</summary>
    public bool Succeeded { get; init; }

    /// <summary>TRNRun exit code, or <see langword="null"/> until it exits or if it never launched.</summary>
    public int? ExitCode { get; init; }

    /// <summary>Execution error reported by the daemon, independent of TRNRun status; empty if none.</summary>
    public string Error { get; init; } = "";

    /// <summary>UTC time the run was added.</summary>
    public DateTimeOffset? SubmittedAt { get; init; }

    /// <summary>UTC time TRNRun started; stays <see langword="null"/> for a run that never started.</summary>
    public DateTimeOffset? StartedAt { get; init; }

    /// <summary>UTC time the run finished, or <see langword="null"/> until then.</summary>
    public DateTimeOffset? FinishedAt { get; init; }

    /// <summary>Whether the daemon finished the run; its logs are then complete.</summary>
    public bool IsFinished => State == SimulationState.Finished;
}

/// <summary>What one <see cref="Database.Poll"/> read: the runs that changed and the new logs.</summary>
/// <param name="Runs">
/// Latest snapshot of each run saved since the previous poll, in the order they last changed.
/// Intermediate states between polls are not kept.
/// </param>
/// <param name="Logs">Log entries saved since the previous poll, oldest first.</param>
public sealed record Changes(IReadOnlyList<SimulationInfo> Runs, IReadOnlyList<LogEvent> Logs)
{
    /// <summary>Changes holding no runs and no logs.</summary>
    public static Changes None { get; } = new([], []);

    /// <summary>Whether nothing changed.</summary>
    public bool IsEmpty => Runs.Count == 0 && Logs.Count == 0;
}
