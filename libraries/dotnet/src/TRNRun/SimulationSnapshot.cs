namespace TRNRun;

/// <summary>Immutable display state captured under a simulation's lock, without copying log history.</summary>
/// <param name="Id">Case-sensitive queue request identifier.</param>
/// <param name="DeckPath">Submitted deck path.</param>
/// <param name="IsAccepted">Whether a queue worker accepted the simulation.</param>
/// <param name="IsFinished">Whether the queue reported completion.</param>
/// <param name="Status">Latest runner status event.</param>
/// <param name="Progress">Latest progress event.</param>
/// <param name="ConfigEvent">Latest native simulation configuration event.</param>
/// <param name="LogCount">Total received log count.</param>
/// <param name="Notices">Received notice count.</param>
/// <param name="Warnings">Received warning count.</param>
/// <param name="Fatals">Received fatal count.</param>
public sealed record SimulationSnapshot(
    string Id,
    string DeckPath,
    bool IsAccepted,
    bool IsFinished,
    StatusEvent? Status,
    ProgressEvent? Progress,
    ConfigEvent? ConfigEvent,
    int LogCount,
    int Notices,
    int Warnings,
    int Fatals)
{
    /// <summary>Gets whether the simulation is waiting or running.</summary>
    public bool IsRunning => !IsFinished;

    /// <summary>Gets whether the latest runner status is terminal.</summary>
    public bool HasTerminalStatus =>
        Status?.Status is
            SimulationStatus.Done
            or SimulationStatus.Cancelled
            or SimulationStatus.Error
            or SimulationStatus.Timeout
            or SimulationStatus.Stalled;

    /// <summary>Gets whether the queue completed the simulation with runner status Done.</summary>
    public bool Succeeded => IsFinished && Status?.Status is SimulationStatus.Done;
}
