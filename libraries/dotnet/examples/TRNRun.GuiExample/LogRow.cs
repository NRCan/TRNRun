namespace TRNRun.GuiExample;

/// <summary>One TRNSYS log entry in the log table.</summary>
/// <param name="Log">The entry trnrund reported.</param>
/// <param name="SimId">Simulation it belongs to.</param>
/// <param name="Run">Label of the run it belongs to.</param>
public sealed record LogRow(LogEvent Log, long SimId, string Run)
{
    /// <summary>Notice, Warning or Fatal.</summary>
    public LogSeverity Severity => Log.Severity;

    /// <summary>Simulated hours at which TRNSYS logged it.</summary>
    public double Time => Log.Time;

    /// <summary>The unit and type that logged it, when TRNSYS says.</summary>
    public string Source => Log.UnitId is { } unit
        ? Log.TypeId is { } type ? $"Unit {unit} · Type {type}" : $"Unit {unit}"
        : "";

    /// <summary>The message with its additional information.</summary>
    public string Message => string.Join(" ", new[] { Log.Message, Log.Information }.Where(text => !string.IsNullOrWhiteSpace(text)));
}
