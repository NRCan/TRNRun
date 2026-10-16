namespace TRNRun;

/// <summary>Lifecycle states reported for a simulation.</summary>
public enum SimulationStatus
{
    /// <summary>The run was validated and is waiting to launch.</summary>
    Pending,
    /// <summary>TRNSYS is starting and readiness detection is under way.</summary>
    Launching,
    /// <summary>TRNSYS is running and being monitored.</summary>
    Running,
    /// <summary>The simulation completed.</summary>
    Done,
    /// <summary>TRNSYS exited before the simulation completed.</summary>
    Cancelled,
    /// <summary>The run failed to launch, crashed, or logged a fatal error.</summary>
    Error,
    /// <summary>The run did not finish within its readiness or monitoring timeout.</summary>
    Timeout,
    /// <summary>Simulation time stopped advancing for too long.</summary>
    Stalled,
}

/// <summary>Base type for native events from one simulation.</summary>
public abstract record TrnRunEvent(string RunId, string Timestamp);

/// <summary>Runner status and optional outcome detail.</summary>
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

/// <summary>Effective native runner settings.</summary>
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

/// <summary>TRNSYS log entry.</summary>
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

/// <summary>Queue worker acceptance or completion event.</summary>
public sealed record QueueEvent(
    string RunId,
    string Timestamp,
    string Status,
    int? ExitCode = null
) : TrnRunEvent(RunId, Timestamp);
