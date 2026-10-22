namespace TRNRun;

/// <summary>What <see cref="TrnrunDatabase.ReadChanges"/> read, and where to read next.</summary>
/// <param name="Runs">Latest snapshot of each changed run, in the order they last changed.</param>
/// <param name="Logs">New log entries, oldest first.</param>
/// <param name="Next">Position to pass to the next <see cref="TrnrunDatabase.ReadChanges"/>.</param>
public sealed record Changes(IReadOnlyList<SimulationInfo> Runs, IReadOnlyList<LogEvent> Logs, ChangePosition Next)
{
    /// <summary>Whether nothing changed.</summary>
    public bool IsEmpty => Runs.Count == 0 && Logs.Count == 0;
}
