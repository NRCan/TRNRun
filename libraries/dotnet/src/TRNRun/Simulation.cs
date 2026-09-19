namespace TRNRun;

/// <summary>Tracks state and events for one queued simulation.</summary>
/// <remarks>
/// State is updated synchronously by the owning manager and is not thread-safe.
/// Queue completion, rather than terminal runner status, finishes the simulation.
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

    /// <summary>Gets a copy of all log events in oldest-first order.</summary>
    public IReadOnlyList<LogEvent> Logs => _logs.ToArray();

    /// <summary>Gets the total number of received log events.</summary>
    public long LogCount { get; private set; }

    /// <summary>Gets the number of notice events.</summary>
    public long Notices { get; private set; }

    /// <summary>Gets the number of warning events.</summary>
    public long Warnings { get; private set; }

    /// <summary>Gets the number of fatal events.</summary>
    public long Fatals { get; private set; }

    /// <summary>Records that a queue worker accepted the simulation.</summary>
    internal void MarkAccepted() => IsAccepted = true;

    /// <summary>Records queue completion for the simulation.</summary>
    internal void MarkCompleted(QueueEvent completion)
    {
        ArgumentNullException.ThrowIfNull(completion);
        if (IsFinished || !string.Equals(completion.RunId, Id, StringComparison.Ordinal))
        {
            return;
        }

        CompletionEvent = completion;
    }

    /// <summary>Applies a routed runner event to the simulation state.</summary>
    internal void ApplyRunnerEvent(TrnRunEvent runEvent)
    {
        ArgumentNullException.ThrowIfNull(runEvent);
        if (IsFinished || !string.Equals(runEvent.RunId, Id, StringComparison.Ordinal))
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
                ApplyLog(log);
                break;
        }
    }

    /// <summary>Retains a log event and updates severity counters.</summary>
    private void ApplyLog(LogEvent log)
    {
        LogCount++;

        if (string.Equals(log.Severity, "Notice", StringComparison.OrdinalIgnoreCase))
        {
            Notices++;
        }
        else if (string.Equals(log.Severity, "Warning", StringComparison.OrdinalIgnoreCase))
        {
            Warnings++;
        }
        else if (string.Equals(log.Severity, "Fatal", StringComparison.OrdinalIgnoreCase))
        {
            Fatals++;
        }

        _logs.Add(log);
    }
}
