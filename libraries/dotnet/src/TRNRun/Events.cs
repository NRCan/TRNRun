namespace TRNRun;

/// <summary>Immutable native message for one simulation.</summary>
/// <param name="RunId">Opaque, case-sensitive queue request identifier.</param>
/// <param name="Timestamp">Native timestamp string; no time zone inferred.</param>
/// <remarks>
/// Events are individual messages, not simulation snapshots. Native sequence numbers are omitted;
/// timestamps and unknown status/severity strings are preserved.
/// </remarks>
public abstract record TrnRunEvent(string RunId, string Timestamp);

/// <summary>Runner status and optional outcome detail.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="Status">Native status string, including unknown values.</param>
/// <param name="Message">Outcome or failure detail; empty when absent.</param>
public sealed record StatusEvent(
    string RunId,
    string Timestamp,
    string Status,
    string Message = ""
) : TrnRunEvent(RunId, Timestamp);

/// <summary>Simulation progress and wall-clock timing.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="Time">Current simulation time in deck units.</param>
/// <param name="Percent">Completion fraction, normally 0 to 1.</param>
/// <param name="Elapsed">Elapsed wall-clock time in milliseconds.</param>
/// <param name="Eta">Estimated remaining wall-clock time in milliseconds.</param>
public sealed record ProgressEvent(
    string RunId,
    string Timestamp,
    double Time,
    double Percent,
    double Elapsed,
    double Eta
) : TrnRunEvent(RunId, Timestamp);

/// <summary>Runner-reported simulation bounds and time step.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="Start">Start time in deck units.</param>
/// <param name="Stop">Stop time in deck units.</param>
/// <param name="Step">Time step in deck units.</param>
public sealed record ConfigEvent(
    string RunId,
    string Timestamp,
    double Start,
    double Stop,
    double Step
) : TrnRunEvent(RunId, Timestamp);

/// <summary>Effective settings; may differ from the submitted <see cref="SimulationConfig"/>.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="TrnExePath">Reported TRNSYS executable path.</param>
/// <param name="GuiVisibility">Native window-visibility string.</param>
/// <param name="WaitForGui">Waits for the TRNSYS window during launch.</param>
/// <param name="WaitForLst">Waits for the component-order header in the deck's .lst file.</param>
/// <param name="WaitForTmp">Waits for the Type3830 .tmp file to exist.</param>
/// <param name="DetectTimeoutMs">Readiness timeout in milliseconds; 0 means unlimited.</param>
/// <param name="ExtraDelayMs">Post-detection delay in milliseconds.</param>
/// <param name="WatchLog">Streams TRNSYS log events.</param>
/// <param name="WatchTmp">Monitors Type3830 progress.</param>
/// <param name="WatchTimeoutMs">Monitoring timeout in milliseconds; 0 means unlimited.</param>
/// <param name="StallTimeoutMs">Stall timeout in milliseconds; 0 disables detection.</param>
/// <param name="PollMs">Monitoring poll interval in milliseconds.</param>
/// <param name="CleanOnSuccess">Deletes .tmp, .log, .lst, and .PTI files after success.</param>
/// <param name="KillOnTimeout">Terminates TRNSYS on a readiness or monitoring timeout.</param>
/// <param name="KillOnStall">Terminates TRNSYS on a stall.</param>
/// <param name="Severity">Native log-severity threshold string.</param>
/// <param name="WriteEvents">Writes runner events to the deck's .jsonl file.</param>
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

/// <summary>TRNSYS log entry; missing optional fields stay null.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="Severity">Native severity string, normally Notice, Warning, or Fatal.</param>
/// <param name="Time">Simulation time in deck units.</param>
/// <param name="UnitId">Emitting unit identifier.</param>
/// <param name="TypeId">Emitting unit's type identifier.</param>
/// <param name="MessageCode">Native message code.</param>
/// <param name="Message">Message text.</param>
/// <param name="Information">Additional detail.</param>
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

/// <summary>Worker acceptance or queue completion; completion alone does not imply <see cref="Simulation.Succeeded"/>.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="Status">Native event field: ACCEPTED on worker pickup before launch; COMPLETED after exit and output drain, or pre-launch failure.</param>
/// <param name="ExitCode">Runner exit code, or null when unavailable.</param>
public sealed record QueueEvent(
    string RunId,
    string Timestamp,
    string Status,
    int? ExitCode = null
) : TrnRunEvent(RunId, Timestamp);
