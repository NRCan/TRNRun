namespace TRNRun;

/// <summary>Severity of a TRNSYS log entry; also used by <see cref="SimulationSettings.Severity"/> to drop less severe ones.</summary>
public enum LogSeverity
{
    /// <summary>Informational entry.</summary>
    Notice,
    /// <summary>Warning entry.</summary>
    Warning,
    /// <summary>Fatal entry; TRNSYS stops the simulation.</summary>
    Fatal,
}
