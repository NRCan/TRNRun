namespace TRNRun.GuiExample;

/// <summary>How a run's status badge is colored.</summary>
public enum RunKind
{
    /// <summary>Waiting for a free slot.</summary>
    Queued,
    /// <summary>TRNRun has started.</summary>
    Running,
    /// <summary>Finished and succeeded.</summary>
    Succeeded,
    /// <summary>Finished with an error, timeout or stall.</summary>
    Failed,
    /// <summary>Finished because it was cancelled.</summary>
    Cancelled,
}
