namespace TRNRun;

/// <summary>The simulation's start, stop and time step, in simulated hours.</summary>
/// <param name="Start">Simulation start time.</param>
/// <param name="Stop">Simulation stop time.</param>
/// <param name="Step">Simulation time step.</param>
public sealed record ConfigEvent(double Start, double Stop, double Step);
