namespace TRNRun;

/// <summary>Daemon lifecycle, <c>Queued → Running → Finished</c>; one that never starts goes straight to <c>Finished</c>.</summary>
public enum SimulationState
{
    /// <summary>Waiting for a worker.</summary>
    Queued,
    /// <summary>TRNRun has started.</summary>
    Running,
    /// <summary>Completed, failed or cancelled; its logs are complete.</summary>
    Finished,
}
