namespace TRNRun;

/// <summary>TRNRun's last reported status of a simulation.</summary>
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
    /// <summary>Cancelled, by the client or the daemon.</summary>
    Cancelled,
    /// <summary>TRNRun failed, could not start, or exited without a final status.</summary>
    Error,
    /// <summary>A detection or watch timeout expired.</summary>
    Timeout,
    /// <summary>No progress within the stall timeout.</summary>
    Stalled,
}
