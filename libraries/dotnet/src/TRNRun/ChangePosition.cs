namespace TRNRun;

/// <summary>Where to read a trnrund database's changes from: after a run revision and a log ID.</summary>
/// <remarks>The default reads the whole history; <see cref="Daemon.StartPosition"/> reads only one daemon's changes.</remarks>
/// <param name="Revision">Runs saved at a later revision are read.</param>
/// <param name="LogId">Log entries with a later ID are read.</param>
public readonly record struct ChangePosition(long Revision, long LogId);
