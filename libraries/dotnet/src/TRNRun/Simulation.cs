namespace TRNRun;

/// <summary>Tracks state and events for one queued simulation.</summary>
/// <remarks>
/// The owning manager folds queue output into this object as it reads, so callers observe
/// updates live rather than through snapshots. State is updated synchronously on the
/// manager's thread and is not thread-safe. Queue completion, rather than terminal runner
/// status, finishes the simulation.
/// </remarks>
public sealed class Simulation
{
    private readonly List<LogEvent> _logs = [];

    /// <summary>Creates pending state for one submitted simulation.</summary>
    internal Simulation(string id, string deckPath, SimulationConfig config)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(id);
        ArgumentException.ThrowIfNullOrWhiteSpace(deckPath);
        ArgumentNullException.ThrowIfNull(config);

        Id = id;
        DeckPath = deckPath;
        Config = config;
        Logs = _logs.AsReadOnly();
    }

    /// <summary>Gets the case-sensitive queue request identifier.</summary>
    public string Id { get; }

    /// <summary>Gets the submitted deck path.</summary>
    public string DeckPath { get; }

    /// <summary>Gets the submitted simulation configuration.</summary>
    public SimulationConfig Config { get; }

    /// <summary>Gets whether a queue worker has accepted the simulation.</summary>
    public bool IsAccepted { get; private set; }

    /// <summary>Gets whether the queue has completed the simulation.</summary>
    public bool IsFinished => CompletionEvent is not null;

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

    /// <summary>
    /// Gets whether the queue completed the simulation with status <see cref="SimulationStatus.Done"/>.
    /// </summary>
    /// <remarks>Exit codes and progress do not determine success.</remarks>
    public bool Succeeded => IsFinished && Status?.Status is SimulationStatus.Done;

    /// <summary>Gets the latest runner status event.</summary>
    public StatusEvent? Status { get; private set; }

    /// <summary>Gets the latest progress event.</summary>
    public ProgressEvent? Progress { get; private set; }

    /// <summary>Gets the latest native simulation configuration event.</summary>
    public ConfigEvent? ConfigEvent { get; private set; }

    /// <summary>Gets the latest effective runner settings event.</summary>
    public SettingEvent? SettingEvent { get; private set; }

    /// <summary>Gets the queue completion event.</summary>
    /// <remarks>
    /// A null event means the run is unfinished. A null exit code can indicate
    /// that the runner could not be launched.
    /// </remarks>
    public QueueEvent? CompletionEvent { get; private set; }

    /// <summary>Gets all retained log events, oldest first.</summary>
    /// <remarks>
    /// Logs are retained without limit. This is a live read-only view that grows as
    /// events arrive; copy it to take a stable snapshot.
    /// </remarks>
    public IReadOnlyList<LogEvent> Logs { get; }

    /// <summary>Gets the total number of received log events.</summary>
    public int LogCount => _logs.Count;

    /// <summary>Gets the number of notice events.</summary>
    public int Notices { get; private set; }

    /// <summary>Gets the number of warning events.</summary>
    public int Warnings { get; private set; }

    /// <summary>Gets the number of fatal events.</summary>
    public int Fatals { get; private set; }

    /// <summary>Records that a queue worker accepted the simulation.</summary>
    internal void MarkAccepted() => IsAccepted = true;

    /// <summary>Records queue completion for the simulation.</summary>
    internal void MarkCompleted(QueueEvent completion)
    {
        if (Accepts(completion))
        {
            CompletionEvent = completion;
        }
    }

    /// <summary>Applies a routed runner event to the simulation state.</summary>
    internal void ApplyRunnerEvent(TrnRunEvent runEvent)
    {
        if (!Accepts(runEvent))
        {
            return;
        }

        switch (runEvent)
        {
            case StatusEvent status:
                Status = status;
                break;

            case ProgressEvent progress:
                Progress = progress;
                break;

            case ConfigEvent config:
                ConfigEvent = config;
                break;

            case SettingEvent setting:
                SettingEvent = setting;
                break;

            case LogEvent log:
                RecordLog(log);
                break;
        }
    }

    /// <summary>Checks that an event belongs to this simulation and still applies to it.</summary>
    /// <remarks>A misrouted event, or any event after queue completion, is ignored.</remarks>
    private bool Accepts(TrnRunEvent runEvent) =>
        !IsFinished && string.Equals(runEvent.RunId, Id, StringComparison.Ordinal);

    /// <summary>Retains a log event and updates the severity counters.</summary>
    /// <remarks>
    /// Unrecognized severities are counted by <see cref="LogCount"/> alone.
    /// </remarks>
    private void RecordLog(LogEvent log)
    {
        _logs.Add(log);

        if (log.Severity.Equals("Notice", StringComparison.OrdinalIgnoreCase))
        {
            Notices++;
        }
        else if (log.Severity.Equals("Warning", StringComparison.OrdinalIgnoreCase))
        {
            Warnings++;
        }
        else if (log.Severity.Equals("Fatal", StringComparison.OrdinalIgnoreCase))
        {
            Fatals++;
        }
    }
}
