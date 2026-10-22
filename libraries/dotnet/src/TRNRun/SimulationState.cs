namespace TRNRun;

/// <summary>Daemon lifecycle, <c>Queued → Running → Finished</c>; a run that never starts goes straight to <see cref="Finished"/>.</summary>
public enum SimulationState
{
    /// <summary>Saved and waiting for a free slot; saved as <c>QUEUED</c>.</summary>
    Queued,
    /// <summary>TRNRun has started; saved as <c>RUNNING</c>.</summary>
    Running,
    /// <summary>Done, failed or cancelled; the run never changes again. Saved as <c>FINISHED</c>.</summary>
    Finished,
}
