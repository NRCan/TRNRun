namespace TRNRun;

/// <summary>One entry of the TRNSYS <c>.log</c> file; the nullable properties are <see langword="null"/> when TRNSYS left them out.</summary>
public sealed record LogEvent
{
    /// <summary>Severity of the entry.</summary>
    public required LogSeverity Severity { get; init; }

    /// <summary>Simulated time of the entry, in hours.</summary>
    public required double Time { get; init; }

    /// <summary>Number of the deck unit that logged it.</summary>
    public int? UnitId { get; init; }

    /// <summary>TRNSYS Type number of that unit.</summary>
    public int? TypeId { get; init; }

    /// <summary>TRNSYS message code.</summary>
    public int? MessageCode { get; init; }

    /// <summary>Message text.</summary>
    public string? Message { get; init; }

    /// <summary>Additional information TRNSYS gave.</summary>
    public string? Information { get; init; }
}
