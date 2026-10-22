namespace TRNRun;

/// <summary>Runner-reported simulation status, saved as its upper-case name, such as <c>DONE</c>.</summary>
public enum SimulationStatus
{
    /// <summary>The run was validated and is waiting to launch.</summary>
    Pending,
    /// <summary>TRNSYS is starting and launch detection is under way.</summary>
    Launching,
    /// <summary>TRNSYS is running and being monitored.</summary>
    Running,
    /// <summary>The simulation completed.</summary>
    Done,
    /// <summary>TRNSYS exited before the simulation completed, or the run was cancelled.</summary>
    Cancelled,
    /// <summary>The run failed to launch, crashed, or logged a fatal error.</summary>
    Error,
    /// <summary>The run did not finish within its detection or watch timeout.</summary>
    Timeout,
    /// <summary>Simulation time stopped advancing for too long.</summary>
    Stalled,
}
