namespace TRNRun;

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
