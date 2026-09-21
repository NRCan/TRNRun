namespace TRNRun;

<<<<<<< HEAD
/// <summary>Base type for native events from one simulation.</summary>
public abstract record TrnRunEvent(string RunId, string Timestamp);

/// <summary>Runner status and optional outcome detail.</summary>
=======
/// <summary>Specifies a runner-reported simulation status.</summary>
public enum SimulationStatus
{
    /// <summary>Waiting to acquire the launch mutex.</summary>
    Pending,
    /// <summary>Preparing and launching the simulation.</summary>
    Launching,
    /// <summary>Monitoring the running simulation.</summary>
    Running,
    /// <summary>Completed without a detected failure.</summary>
    Done,
    /// <summary>Cancelled or ended with incomplete tracked progress.</summary>
    Cancelled,
    /// <summary>Failed during validation, launch, or monitoring.</summary>
    Error,
    /// <summary>Exceeded a readiness or monitoring timeout.</summary>
    Timeout,
    /// <summary>Stopped making tracked simulation progress.</summary>
    Stalled,
}

/// <summary>Immutable native event for one simulation.</summary>
/// <remarks>Native timestamps and severity strings are preserved.</remarks>
public abstract record TrnRunEvent(string RunId, string Timestamp);

/// <summary>Runner status and outcome detail.</summary>
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
public sealed record StatusEvent(
    string RunId,
    string Timestamp,
    SimulationStatus Status,
    string Message = ""
) : TrnRunEvent(RunId, Timestamp);

/// <summary>Simulation progress and wall-clock timing.</summary>
public sealed record ProgressEvent(
    string RunId,
    string Timestamp,
    double Time,
    double Percent,
    double Elapsed,
    double Eta
) : TrnRunEvent(RunId, Timestamp);

/// <summary>Runner-reported simulation bounds and time step.</summary>
public sealed record ConfigEvent(
    string RunId,
    string Timestamp,
    double Start,
    double Stop,
    double Step
) : TrnRunEvent(RunId, Timestamp);

<<<<<<< HEAD
/// <summary>Effective native runner settings.</summary>
=======
/// <summary>Effective runner settings for the simulation.</summary>
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
public sealed record SettingEvent(
    string RunId,
    string Timestamp,
    string TrnExePath,
    string GuiVisibility,
    bool WaitForGui,
    bool WaitForLst,
    bool WaitForTmp,
    long DetectTimeoutMs,
    long ExtraDelayMs,
    bool WatchLog,
    bool WatchTmp,
    long WatchTimeoutMs,
    long StallTimeoutMs,
    long PollMs,
    bool CleanOnSuccess,
    bool KillOnTimeout,
    bool KillOnStall,
    string Severity,
    bool WriteEvents
) : TrnRunEvent(RunId, Timestamp);

<<<<<<< HEAD
/// <summary>TRNSYS log entry.</summary>
=======
/// <summary>TRNSYS log entry with optional context and message details.</summary>
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
public sealed record LogEvent(
    string RunId,
    string Timestamp,
    string Severity,
    double? Time = null,
    long? UnitId = null,
    long? TypeId = null,
    long? MessageCode = null,
    string? Message = null,
    string? Information = null
) : TrnRunEvent(RunId, Timestamp);

<<<<<<< HEAD
/// <summary>Queue worker acceptance or completion event.</summary>
=======
/// <summary>Queue worker acceptance or completion.</summary>
/// <remarks>Completion alone does not imply <see cref="Simulation.Succeeded"/>.</remarks>
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
public sealed record QueueEvent(
    string RunId,
    string Timestamp,
    string Status,
    int? ExitCode = null
) : TrnRunEvent(RunId, Timestamp);
