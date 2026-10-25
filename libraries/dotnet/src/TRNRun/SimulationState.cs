namespace TRNRun;

/// <summary>Where trnrund is with a simulation: <c>Queued</c>, then <c>Running</c>, then <c>Finished</c>; one that never starts skips <c>Running</c>.</summary>
public enum SimulationState
{
    /// <summary>Waiting for a worker.</summary>
    Queued,
    /// <summary>TRNRun has started.</summary>
    Running,
    /// <summary>Succeeded, failed or cancelled; nothing about it changes any more.</summary>
    Finished,
}
