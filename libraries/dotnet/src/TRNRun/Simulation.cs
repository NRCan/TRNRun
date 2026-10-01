namespace TRNRun;

/// <summary>Synchronized event state for one queued simulation.</summary>
/// <remarks>
/// Individual state reads are thread-safe. Use <see cref="Snapshot"/> for a coherent view of
/// multiple fields. Queue completion, rather than terminal runner status, finishes the simulation.
/// </remarks>
public sealed class Simulation
{
    private readonly object _lock = new();
    private readonly List<LogEvent> _logs = [];
    private bool _accepted;
    private StatusEvent? _status;
    private ProgressEvent? _progress;
    private ConfigEvent? _configEvent;
    private SettingEvent? _settingEvent;
    private QueueEvent? _completionEvent;
    private int _notices;
    private int _warnings;
    private int _fatals;

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

    /// <summary>Gets the immutable submitted simulation configuration.</summary>
    public SimulationConfig Config { get; }

    /// <summary>Gets whether a queue worker has accepted the simulation.</summary>
    public bool IsAccepted
    {
        get { lock (_lock) { return _accepted; } }
    }

    /// <summary>Gets whether the queue has completed the simulation.</summary>
    public bool IsFinished
    {
        get { lock (_lock) { return _completionEvent is not null; } }
    }

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
    /// <remarks>Exit codes and progress do not determine success.</remarks>
    public bool Succeeded
    {
        get
        {
            lock (_lock)
            {
                return _completionEvent is not null && _status?.Status is SimulationStatus.Done;
            }
        }
    }

    /// <summary>Gets the latest runner status event.</summary>
    public StatusEvent? Status
    {
        get { lock (_lock) { return _status; } }
    }

    /// <summary>Gets the latest progress event.</summary>
    public ProgressEvent? Progress
    {
        get { lock (_lock) { return _progress; } }
    }

    /// <summary>Gets the latest native simulation configuration event.</summary>
    public ConfigEvent? ConfigEvent
    {
        get { lock (_lock) { return _configEvent; } }
    }

    /// <summary>Gets the latest effective runner settings event.</summary>
    public SettingEvent? SettingEvent
    {
        get { lock (_lock) { return _settingEvent; } }
    }

    /// <summary>Gets the queue completion event.</summary>
    /// <remarks>
    /// A null event means the run is unfinished. A null exit code can indicate
    /// that the runner could not be launched.
    /// </remarks>
    public QueueEvent? CompletionEvent
    {
        get { lock (_lock) { return _completionEvent; } }
    }

    /// <summary>Gets a stable copy of all retained log events, oldest first.</summary>
    /// <remarks>Full log history is retained without limit. Use Snapshot for display state without copying logs.</remarks>
    public IReadOnlyList<LogEvent> Logs
    {
        get { lock (_lock) { return _logs.ToArray(); } }
    }

    /// <summary>Gets the total number of received log events.</summary>
    public int LogCount
    {
        get { lock (_lock) { return _logs.Count; } }
    }

    /// <summary>Gets the number of notice events.</summary>
    public int Notices
    {
        get { lock (_lock) { return _notices; } }
    }

    /// <summary>Gets the number of warning events.</summary>
    public int Warnings
    {
        get { lock (_lock) { return _warnings; } }
    }

    /// <summary>Gets the number of fatal events.</summary>
    public int Fatals
    {
        get { lock (_lock) { return _fatals; } }
    }

    /// <summary>Captures coherent display state without copying logs or detailed runner/queue metadata.</summary>
    public SimulationSnapshot Snapshot()
    {
        lock (_lock)
        {
            return new SimulationSnapshot(
                Id, DeckPath, _accepted, _completionEvent is not null, _status, _progress,
                _configEvent, _logs.Count, _notices, _warnings, _fatals);
        }
    }

    /// <summary>Applies a routed event, returning whether it changed state.</summary>
    /// <remarks>Misrouted events, duplicate acceptance, unknown queue events, and events after completion are ignored.</remarks>
    internal bool ApplyEvent(TrnRunEvent runEvent)
    {
        lock (_lock)
        {
            if (_completionEvent is not null || !string.Equals(runEvent.RunId, Id, StringComparison.Ordinal))
            {
                return false;
            }

            switch (runEvent)
            {
                case QueueEvent { Status: "ACCEPTED" } when !_accepted:
                    _accepted = true;
                    break;
                case QueueEvent { Status: "COMPLETED" } completion:
                    _completionEvent = completion;
                    break;
                case QueueEvent:
                    return false;
                case StatusEvent status:
                    _status = status;
                    break;
                case ProgressEvent progress:
                    _progress = progress;
                    break;
                case ConfigEvent config:
                    _configEvent = config;
                    break;
                case SettingEvent setting:
                    _settingEvent = setting;
                    break;
                case LogEvent log:
                    RecordLog(log);
                    break;
                default:
                    return false;
            }

            return true;
        }
    }

    private void RecordLog(LogEvent log)
    {
        _logs.Add(log);
        if (log.Severity.Equals("Notice", StringComparison.OrdinalIgnoreCase))
        {
            _notices++;
        }
        else if (log.Severity.Equals("Warning", StringComparison.OrdinalIgnoreCase))
        {
            _warnings++;
        }
        else if (log.Severity.Equals("Fatal", StringComparison.OrdinalIgnoreCase))
        {
            _fatals++;
        }
    }
}
