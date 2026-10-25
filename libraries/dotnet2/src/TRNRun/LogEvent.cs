namespace TRNRun;

/// <summary>One TRNSYS log entry; the properties after <see cref="Time"/> are <see langword="null"/> unless TRNSYS attached them.</summary>
public sealed record LogEvent
{
    /// <summary>Severity of the entry.</summary>
    public required LogSeverity Severity { get; init; }

    /// <summary>Simulation time of the entry, in simulated hours.</summary>
    public required double Time { get; init; }

    /// <summary>Unit that emitted the entry.</summary>
    public int? UnitId { get; init; }

    /// <summary>Type of the unit that emitted the entry.</summary>
    public int? TypeId { get; init; }

    /// <summary>TRNSYS message code.</summary>
    public int? MessageCode { get; init; }

    /// <summary>Message text.</summary>
    public string? Message { get; init; }

    /// <summary>Additional information TRNSYS gave.</summary>
    public string? Information { get; init; }
}
