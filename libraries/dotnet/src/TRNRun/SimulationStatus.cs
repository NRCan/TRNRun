namespace TRNRun;

/// <summary>TRNRun's latest status for a simulation, more detailed than <see cref="SimulationState"/>.</summary>
public enum SimulationStatus
{
    /// <summary>Not launched yet.</summary>
    Pending,
    /// <summary>TRNSYS is starting.</summary>
    Launching,
    /// <summary>TRNSYS is running.</summary>
    Running,
    /// <summary>TRNSYS completed.</summary>
    Done,
    /// <summary>Cancelled, by <see cref="TRNRunDaemon.CancelAsync"/> or by trnrund itself.</summary>
    Cancelled,
    /// <summary>TRNRun failed, could not start, or exited without a final status.</summary>
    Error,
    /// <summary>A detection or watch timeout expired.</summary>
    Timeout,
    /// <summary>No progress within <see cref="SimulationSettings.StallTimeout"/>.</summary>
    Stalled,
}
