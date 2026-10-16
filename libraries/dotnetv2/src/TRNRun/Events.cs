namespace TRNRun;

// The TRNRun events trnrund saves, as typed values. They mirror the events of
// trnrund's events.nim; LogEvent also carries the log ID and run ID of its row.

/// <summary>Runner-reported simulation status.</summary>
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

/// <summary>The settings TRNRun reported applying, with its defaults filled in.</summary>
/// <remarks>
/// Each property is the <see cref="SimulationSettings"/> property of the same name, which
/// documents it; durations are in milliseconds.
/// </remarks>
/// <param name="TrnexePath">TRNSYS executable.</param>
/// <param name="GuiVisibility">TRNSYS window behavior, as TRNRun names it, such as <c>hidden</c>.</param>
/// <param name="WaitForGui">Whether launch detection waited for a TRNSYS GUI.</param>
/// <param name="WaitForLst">Whether launch detection waited for the <c>.lst</c> header.</param>
/// <param name="WaitForTmp">Whether launch detection waited for the <c>.tmp</c> file.</param>
/// <param name="DetectTimeoutMs">Launch-detection timeout; 0 means unlimited.</param>
/// <param name="ExtraDelayMs">Delay after detection passed.</param>
/// <param name="WatchLog">Whether <c>.log</c> entries are streamed.</param>
/// <param name="WatchTmp">Whether <c>.tmp</c> progress is streamed.</param>
/// <param name="WatchTimeoutMs">Runtime-monitoring timeout; 0 means unlimited.</param>
/// <param name="StallTimeoutMs">No-progress timeout; 0 disables it.</param>
/// <param name="PollMs">Polling interval.</param>
/// <param name="CleanOnSuccess">Whether TRNSYS artifacts are deleted on success.</param>
/// <param name="KillOnTimeout">Whether TRNSYS is killed on a timeout.</param>
/// <param name="KillOnStall">Whether TRNSYS is killed on a stall.</param>
/// <param name="Severity">Minimum emitted log severity, such as <c>Notice</c>.</param>
/// <param name="WriteEvents">Whether events are written to a <c>.jsonl</c> file beside the deck.</param>
public sealed record SettingEvent(
    string TrnexePath,
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
    bool WriteEvents);

/// <summary>The run's latest TRNRun status.</summary>
/// <param name="Status">State reported by TRNRun.</param>
/// <param name="Message">Optional outcome or failure detail reported by TRNRun.</param>
public sealed record StatusEvent(SimulationStatus Status, string Message = "");

/// <summary>The run's latest completion and timing.</summary>
/// <param name="Time">Current simulation time, in simulated hours.</param>
/// <param name="Percent">Completion of the run as a fraction from 0 to 1.</param>
/// <param name="ElapsedMs">Wall-clock milliseconds elapsed since the run started.</param>
/// <param name="EtaMs">Estimated wall-clock milliseconds remaining.</param>
public sealed record ProgressEvent(double Time, double Percent, double ElapsedMs, double EtaMs);

/// <summary>The simulation's time bounds and step, in simulated hours.</summary>
/// <param name="Start">Simulation start time.</param>
/// <param name="Stop">Simulation stop time.</param>
/// <param name="Step">Simulation time step.</param>
public sealed record ConfigEvent(double Start, double Stop, double Step);

/// <summary>One severity-tagged TRNSYS log entry.</summary>
/// <remarks>
/// Only <see cref="Severity"/> and <see cref="Time"/> are guaranteed; the remaining properties
/// depend on what TRNSYS attaches to the message.
/// </remarks>
/// <param name="LogId">Position of the entry among every run's logs; grows with each entry.</param>
/// <param name="RunId">Run the entry belongs to.</param>
/// <param name="Severity">Severity tag: <c>Notice</c>, <c>Warning</c> or <c>Fatal</c>.</param>
/// <param name="Time">Simulation time at which the message was produced.</param>
/// <param name="UnitId">Unit that emitted the message.</param>
/// <param name="TypeId">Type of the unit that emitted the message.</param>
/// <param name="MessageCode">Numeric code identifying the message.</param>
/// <param name="Message">Human-readable message text.</param>
/// <param name="Information">Additional detail attached to the message.</param>
public sealed record LogEvent(
    long LogId,
    long RunId,
    string Severity,
    double Time,
    long? UnitId = null,
    long? TypeId = null,
    long? MessageCode = null,
    string? Message = null,
    string? Information = null);
