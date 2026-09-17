namespace TRNRun;

/// <summary>Immutable native message associated with one simulation.</summary>
/// <param name="RunId">Opaque, case-sensitive queue request identifier.</param>
/// <param name="Timestamp">Native timestamp string, without an inferred time zone.</param>
/// <remarks>
/// Events describe individual messages, not simulation snapshots. The manager routes them by
/// <see cref="RunId"/> and updates the associated <see cref="Simulation"/> while reading queue output.
/// Native sequence numbers are omitted; timestamps and unknown status/severity strings are preserved.
/// </remarks>
public abstract record TrnRunEvent(
    string RunId,
    string Timestamp
);

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

/// <summary>Simulation time bounds and step reported by the runner.</summary>
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

/// <summary>Effective settings reported by the native runner.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="TrnExePath">Reported TRNSYS executable path.</param>
/// <param name="GuiVisibility">Native window-visibility string.</param>
/// <param name="WaitForGui">Whether launch detection waits for the TRNSYS GUI.</param>
/// <param name="WaitForLst">Whether launch detection waits for the listing file.</param>
/// <param name="WaitForTmp">Whether launch detection waits for the Type3830 progress file.</param>
/// <param name="DetectTimeoutMs">Readiness timeout in milliseconds; 0 means unlimited.</param>
/// <param name="ExtraDelayMs">Post-detection delay in milliseconds.</param>
/// <param name="WatchLog">Whether to monitor the TRNSYS log.</param>
/// <param name="WatchTmp">Whether to monitor Type3830 progress.</param>
/// <param name="WatchTimeoutMs">Monitoring timeout in milliseconds; 0 means unlimited.</param>
/// <param name="StallTimeoutMs">Stall timeout in milliseconds; 0 disables detection.</param>
/// <param name="PollMs">Monitoring poll interval in milliseconds.</param>
/// <param name="CleanOnSuccess">Whether to clean intermediate files after success.</param>
/// <param name="KillOnTimeout">Whether to terminate TRNSYS on timeout.</param>
/// <param name="KillOnStall">Whether to terminate TRNSYS on a stall.</param>
/// <param name="Severity">Native log-severity threshold string.</param>
/// <param name="WriteEvents">Whether to write an event JSON Lines file.</param>
/// <remarks>
/// Reports what the runner applied, which may differ from the submitted <see cref="SimulationConfig"/>.
/// Native strings and integer milliseconds are retained without conversion to enums or TimeSpan,
/// preserving normalized settings and unknown future values.
/// </remarks>
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

/// <summary>Severity-tagged TRNSYS log entry.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="Severity">Native severity string, normally Notice, Warning, or Fatal.</param>
/// <param name="Time">Simulation time in deck units.</param>
/// <param name="UnitId">Emitting unit identifier.</param>
/// <param name="TypeId">Emitting unit's type identifier.</param>
/// <param name="MessageCode">Native message code.</param>
/// <param name="Message">Message text.</param>
/// <param name="Information">Additional detail.</param>
/// <remarks>Absent optional fields remain <see langword="null"/>.</remarks>
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

/// <summary>Worker acceptance or queue completion for one run.</summary>
/// <param name="RunId">Queue request identifier.</param>
/// <param name="Timestamp">Native timestamp.</param>
/// <param name="Status">Native event field, normally ACCEPTED or COMPLETED.</param>
/// <param name="ExitCode">Runner exit code, or null when unavailable.</param>
/// <remarks>
/// ACCEPTED marks worker pickup, before launch. COMPLETED follows runner exit and output draining,
/// or a pre-launch failure. A null exit code is not zero; completion alone does not establish success.
/// <see cref="Simulation.Succeeded"/> also requires the latest runner status to be exactly DONE.
/// </remarks>
public sealed record QueueEvent(
    string RunId,
    string Timestamp,
    string Status,
    int? ExitCode = null
) : TrnRunEvent(RunId, Timestamp);
