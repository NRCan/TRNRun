using System.Text.Json;

namespace TRNRun;

// The typed records read from a trnrund database: runs, their TRNRun events, and their logs.
// The event types mirror trnrund's events.nim. STATUS and SETTING have no record: they are
// properties of SimulationInfo.

// -----------------------------------------------------------------
// Enums
// -----------------------------------------------------------------

/// <summary>Daemon lifecycle, <c>Queued → Running → Finished</c>; a run that never starts goes straight to <see cref="Finished"/>.</summary>
public enum SimulationState
{
    /// <summary>Saved and waiting for a free slot; saved as <c>QUEUED</c>.</summary>
    Queued,
    /// <summary>TRNRun has started; saved as <c>RUNNING</c>.</summary>
    Running,
    /// <summary>Done, failed or cancelled; the run never changes again. Saved as <c>FINISHED</c>.</summary>
    Finished,
}

/// <summary>Runner-reported simulation status, saved as its upper-case name, such as <c>DONE</c>.</summary>
public enum SimulationStatus
{
    /// <summary>The run was validated and is waiting to launch.</summary>
    Pending,
    /// <summary>TRNSYS is starting and launch detection is under way.</summary>
    Launching,
    /// <summary>TRNSYS is running and being monitored.</summary>
    Running,
    /// <summary>The simulation completed.</summary>
    Done,
    /// <summary>TRNSYS exited before the simulation completed, or the run was cancelled.</summary>
    Cancelled,
    /// <summary>The run failed to launch, crashed, or logged a fatal error.</summary>
    Error,
    /// <summary>The run did not finish within its detection or watch timeout.</summary>
    Timeout,
    /// <summary>Simulation time stopped advancing for too long.</summary>
    Stalled,
}

/// <summary>Severity of a TRNSYS log entry, also the minimum one TRNRun emits (<c>--severity</c>).</summary>
public enum LogSeverity
{
    /// <summary>Informational entry.</summary>
    Notice,
    /// <summary>Warning entry.</summary>
    Warning,
    /// <summary>Fatal entry; TRNSYS stops the simulation.</summary>
    Fatal,
}

// -----------------------------------------------------------------
// Events
// -----------------------------------------------------------------

/// <summary>The run's latest completion and timing.</summary>
/// <param name="Time">Current simulation time, in simulated hours.</param>
/// <param name="Percent">Completion of the run as a fraction from 0 to 1.</param>
/// <param name="ElapsedMs">Wall-clock milliseconds elapsed since the run started.</param>
/// <param name="EtaMs">Estimated wall-clock milliseconds remaining.</param>
public sealed record ProgressEvent(double Time, double Percent, double ElapsedMs, double EtaMs);

/// <summary>The simulation's start, stop and time step, in simulated hours.</summary>
/// <param name="Start">Simulation start time.</param>
/// <param name="Stop">Simulation stop time.</param>
/// <param name="Step">Simulation time step.</param>
public sealed record ConfigEvent(double Start, double Stop, double Step);

/// <summary>One TRNSYS log entry; the properties after <paramref name="Time"/> are <see langword="null"/> unless TRNSYS attached them.</summary>
/// <param name="LogId">Position among every run's logs; grows with each entry.</param>
/// <param name="RunId">Run the entry belongs to.</param>
/// <param name="Severity">Severity of the entry.</param>
/// <param name="Time">Simulation time of the message, in simulated hours.</param>
/// <param name="UnitId">Unit that emitted the message.</param>
/// <param name="TypeId">Type of the unit that emitted the message.</param>
/// <param name="MessageCode">Numeric code identifying the message.</param>
/// <param name="Message">Message text.</param>
/// <param name="Information">Additional detail attached to the message.</param>
public sealed record LogEvent(
    long LogId,
    long RunId,
    LogSeverity Severity,
    double Time,
    long? UnitId = null,
    long? TypeId = null,
    long? MessageCode = null,
    string? Message = null,
    string? Information = null);

// -----------------------------------------------------------------
// Runs
// -----------------------------------------------------------------

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
    public long SessionId { get; init; }

    /// <summary>Tag the run was added with.</summary>
    public string? Label { get; init; }

    /// <summary>Revision of the run's latest save.</summary>
    public long Revision { get; init; }

    /// <summary>TRNRun options the run was added with.</summary>
    public IReadOnlyList<string> TrnrunArgs { get; init; } = [];

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
    public int Notices { get; init; }

    /// <summary>Warning log entries saved so far.</summary>
    public int Warnings { get; init; }

    /// <summary>Fatal log entries saved so far.</summary>
    public int Fatals { get; init; }

    /// <summary>Whether it finished with <c>DONE</c>, exit code 0 and no error; <see langword="null"/> until it finishes.</summary>
    public bool? Succeeded { get; init; }

    /// <summary>TRNRun's exit code.</summary>
    public int? ExitCode { get; init; }

    /// <summary>Execution error reported by the daemon.</summary>
    public string? Error { get; init; }

    /// <summary>UTC time the run was added.</summary>
    public DateTimeOffset? SubmittedAt { get; init; }

    /// <summary>UTC time TRNRun started; stays <see langword="null"/> for a run that never started.</summary>
    public DateTimeOffset? StartedAt { get; init; }

    /// <summary>UTC time the run finished.</summary>
    public DateTimeOffset? FinishedAt { get; init; }

    /// <summary>Whether the daemon finished the run; its logs are then complete.</summary>
    public bool IsFinished => State == SimulationState.Finished;
}

/// <summary>Where to read a trnrund database's changes from: after a run revision and a log ID.</summary>
/// <remarks>The default reads the whole history; <see cref="Daemon.StartPosition"/> reads only one daemon's changes.</remarks>
/// <param name="Revision">Runs saved at a later revision are read.</param>
/// <param name="LogId">Log entries with a later ID are read.</param>
public readonly record struct ChangePosition(long Revision, long LogId);

/// <summary>What <see cref="TrnrunDatabase.ReadChanges"/> read, and where to read next.</summary>
/// <param name="Runs">Latest snapshot of each changed run, in the order they last changed.</param>
/// <param name="Logs">New log entries, oldest first.</param>
/// <param name="Next">Position to pass to the next <see cref="TrnrunDatabase.ReadChanges"/>.</param>
public sealed record Changes(IReadOnlyList<SimulationInfo> Runs, IReadOnlyList<LogEvent> Logs, ChangePosition Next)
{
    /// <summary>Whether nothing changed.</summary>
    public bool IsEmpty => Runs.Count == 0 && Logs.Count == 0;
}
