namespace TRNRun;

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
