namespace TRNRun;

/// <summary>The run's latest completion and timing.</summary>
/// <param name="Time">Current simulation time, in simulated hours.</param>
/// <param name="Percent">Completion of the run as a fraction from 0 to 1.</param>
/// <param name="Elapsed">Wall-clock time elapsed since the run started.</param>
/// <param name="Eta">Estimated wall-clock time remaining; zero until progress is measurable.</param>
public sealed record ProgressEvent(double Time, double Percent, TimeSpan Elapsed, TimeSpan Eta);
