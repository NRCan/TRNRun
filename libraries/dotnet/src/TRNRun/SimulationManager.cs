using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using TRNRun.Display;
using TRNRun.Internal;

namespace TRNRun;

/// <summary>Submits and monitors simulations through one continuously read queue process.</summary>
/// <remarks>
/// Queue output is consumed on a background thread. Callbacks must return promptly and must not
/// submit work or call blocking manager operations. GUI applications can read snapshots on their UI thread.
/// Shutdown is owner-controlled, must not be concurrent or reentrant, and terminates unfinished work.
/// Call Wait first to finish desired work. No simulation outcomes are synthesized on queue failure.
/// </remarks>
public sealed class SimulationManager : IDisposable
{
    private readonly object _condition = new();
    private readonly QueueProcess _queue;
    private readonly ConsoleDisplay _display;
    private readonly List<Simulation> _simulations = [];
    private readonly Dictionary<string, Simulation> _byId = new(StringComparer.Ordinal);
    private readonly Dictionary<string, long> _versions = new(StringComparer.Ordinal);
    private long _nextId = 1;
    private long _updateVersion;
    private bool _closed;
    private bool _cleanupComplete;
    private bool _readerStopped;
    private Exception? _readerError;
    private int _readerThreadId;
    private int _showProgress;

    /// <summary>Starts the queue and its background reader, and configures progress rendering.</summary>
    /// <param name="maxConcurrent">Positive worker count; defaults to processor count minus one, at least one.</param>
    /// <param name="refreshInterval">Positive display refresh interval; defaults to one second, independent of pipe reading.</param>
    /// <param name="trnRunQueuePath">Unquoted queue executable path, or null to use the bundled executable.</param>
    public SimulationManager(
        int? maxConcurrent = null,
        TimeSpan? refreshInterval = null,
        string? trnRunQueuePath = null)
    {
        int concurrency = maxConcurrent ?? Math.Max(Environment.ProcessorCount - 1, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(concurrency, 1, nameof(maxConcurrent));
        _display = new ConsoleDisplay(refreshInterval ?? TimeSpan.FromSeconds(1));

        string executable =
            trnRunQueuePath ?? Path.Combine(AppContext.BaseDirectory, "native", "trnrunq.exe");
        _queue = new QueueProcess(Path.GetFullPath(executable), concurrency, OnQueueOutput, OnQueueExit);
    }

    /// <summary>Gets or sets whether to render console progress on queue updates; defaults to false.</summary>
    public bool ShowProgress
    {
        get => Volatile.Read(ref _showProgress) != 0;
        set => Volatile.Write(ref _showProgress, value ? 1 : 0);
    }

    /// <summary>Notifies subscribers after an event is applied to a simulation.</summary>
    /// <remarks>
    /// Handlers run on the queue reader thread, outside the manager lock, and must return promptly.
    /// Do not call Add, Wait, Follow, Shutdown, or Dispose from a handler. Marshal GUI work
    /// to its UI thread. Each handler's exceptions are isolated so they cannot stop output consumption.
    /// </remarks>
    public event Action<Simulation, TrnRunEvent>? SimulationUpdated;

    /// <summary>Gets a copy of all tracked handles in submission order, including pending submissions.</summary>
    /// <remarks>Failed sends are removed unless the queue already accepted the simulation.</remarks>
    public IReadOnlyList<Simulation> Submitted
    {
        get { lock (_condition) { return _simulations.ToArray(); } }
    }

    /// <summary>Gets a copy of queue-accepted simulations in submission order.</summary>
    public IReadOnlyList<Simulation> Simulations
    {
        get { lock (_condition) { return _simulations.Where(item => item.IsAccepted).ToArray(); } }
    }

    /// <summary>Gets a copy of unfinished simulations, including pending submissions.</summary>
    public IReadOnlyList<Simulation> Active
    {
        get { lock (_condition) { return _simulations.Where(item => !item.IsFinished).ToArray(); } }
    }

    /// <summary>Gets a copy of accepted simulations that completed successfully.</summary>
    public IReadOnlyList<Simulation> Succeeded
    {
        get { lock (_condition) { return _simulations.Where(item => item.IsAccepted && item.Succeeded).ToArray(); } }
    }

    /// <summary>Gets a copy of accepted, finished simulations that did not succeed.</summary>
    public IReadOnlyList<Simulation> Failed
    {
        get
        {
            lock (_condition)
            {
                return _simulations.Where(item => item.IsAccepted && item.IsFinished && !item.Succeeded).ToArray();
            }
        }
    }

    /// <summary>Submits a deck, optionally blocking until a queue worker accepts it.</summary>
    /// <param name="deckPath">Unquoted path to an existing deck file.</param>
    /// <param name="config">Immutable settings validated before sending.</param>
    /// <param name="blocking">Whether to wait for acceptance; false returns after the synchronous request write.</param>
    /// <remarks>Concurrent submissions are supported. Writes occur outside the manager lock and are not retried.</remarks>
    public Simulation Add(string deckPath, SimulationConfig config, bool blocking = true)
    {
        ArgumentNullException.ThrowIfNull(config);
        ThrowIfReaderThread();

        string fullDeckPath = Path.GetFullPath(deckPath);
        if (!File.Exists(fullDeckPath))
        {
            throw new FileNotFoundException($"Deck file not found: '{fullDeckPath}'.", fullDeckPath);
        }

        string[] arguments = config.ToCliArgs(out string runnerPath);
        Simulation simulation;
        lock (_condition)
        {
            ThrowIfClosed();
            ThrowIfReaderStopped();
            string id = _nextId.ToString(CultureInfo.InvariantCulture);
            _nextId++;
            simulation = new Simulation(id, fullDeckPath, config);
            // Register before sending: acceptance can arrive before Send returns.
            _simulations.Add(simulation);
            _byId.Add(id, simulation);
        }

        try
        {
            // A full stdin pipe must not prevent the reader from taking the manager lock.
            _queue.Send(new QueueRequest(
                RunId: simulation.Id,
                DeckFile: fullDeckPath,
                RunnerPath: runnerPath,
                RunnerArgs: arguments));
        }
        catch
        {
            lock (_condition)
            {
                if (!simulation.IsAccepted)
                {
                    _simulations.Remove(simulation);
                    _byId.Remove(simulation.Id);
                    _versions.Remove(simulation.Id);
                }

                Monitor.PulseAll(_condition);
            }

            throw;
        }

        if (blocking)
        {
            lock (_condition)
            {
                while (!simulation.IsAccepted && !_closed && !_readerStopped)
                {
                    Monitor.Wait(_condition);
                }

                ThrowIfClosed();
                if (!simulation.IsAccepted)
                {
                    ThrowIfReaderStopped();
                }
            }
        }

        return simulation;
    }

    /// <summary>Waits for one owned simulation, or all outstanding submissions, to finish.</summary>
    /// <remarks>The background reader continues updating every run. Waiting does not close the queue.</remarks>
    public void Wait(Simulation? simulation = null)
    {
        ThrowIfReaderThread();
        lock (_condition)
        {
            ThrowIfClosed();
            ValidateOwnership(simulation);
            while (!Finished(simulation) && !_closed && !_readerStopped)
            {
                Monitor.Wait(_condition);
            }

            ThrowIfClosed();
            if (!Finished(simulation))
            {
                ThrowIfReaderStopped();
            }
        }
    }

    /// <summary>Observes updates for one owned simulation, or all submissions, until completion.</summary>
    /// <remarks>
    /// Yields live handles without replaying past events. Slow observers coalesce intervening events
    /// into the latest state per simulation; use SimulationUpdated to receive individual events.
    /// Pausing or ending enumeration does not stop queue reading. Validation starts when enumerated.
    /// </remarks>
    public IEnumerable<Simulation> Follow(Simulation? simulation = null)
    {
        ThrowIfReaderThread();
        long observedVersion;
        lock (_condition)
        {
            ThrowIfClosed();
            ValidateOwnership(simulation);
            observedVersion = _updateVersion;
        }

        while (true)
        {
            Simulation[] updates;
            lock (_condition)
            {
                while (true)
                {
                    ThrowIfClosed();
                    updates = _simulations.Where(item =>
                        (simulation is null || ReferenceEquals(simulation, item)) &&
                        _versions.TryGetValue(item.Id, out long version) && version > observedVersion).ToArray();
                    observedVersion = _updateVersion;
                    if (updates.Length > 0)
                    {
                        break;
                    }

                    if (Finished(simulation))
                    {
                        yield break;
                    }

                    ThrowIfReaderStopped();
                    Monitor.Wait(_condition);
                }
            }

            foreach (Simulation updated in updates)
            {
                yield return updated;
            }
        }
    }

    /// <summary>Terminates the queue and releases resources, retrying incomplete cleanup if necessary.</summary>
    /// <remarks>
    /// This does not drain unfinished work; call Wait first when completion is desired. Shutdown wakes
    /// blocked operations, and successful repeated calls are harmless. Queue cleanup uses bounded waits.
    /// The owner must prevent concurrent or reentrant shutdown and must not call it from a callback.
    /// </remarks>
    public void Shutdown()
    {
        ThrowIfReaderThread();
        lock (_condition)
        {
            if (_cleanupComplete)
            {
                return;
            }

            _closed = true;
            Monitor.PulseAll(_condition);
        }

        _queue.Shutdown();
        lock (_condition)
        {
            _cleanupComplete = true;
        }
    }

    /// <summary>Performs the same shutdown as Shutdown, enabling using statements.</summary>
    public void Dispose() => Shutdown();

    private void OnQueueExit(Exception? error)
    {
        Volatile.Write(ref _readerThreadId, Environment.CurrentManagedThreadId);
        lock (_condition)
        {
            _readerError = error;
            _readerStopped = true;
            Monitor.PulseAll(_condition);
        }
    }

    private void OnQueueOutput(string line)
    {
        Volatile.Write(ref _readerThreadId, Environment.CurrentManagedThreadId);
        TrnRunEvent? runEvent;
        try
        {
            runEvent = EventParser.Parse(line);
        }
        catch (JsonException error)
        {
            Debug.WriteLine($"Dropped malformed queue line: {line}\n{error}");
            return;
        }

        if (runEvent is null)
        {
            return;
        }

        Simulation simulation;
        lock (_condition)
        {
            if (_closed || !_byId.TryGetValue(runEvent.RunId, out Simulation? found) || !found.ApplyEvent(runEvent))
            {
                return;
            }

            simulation = found;
            _versions[simulation.Id] = ++_updateVersion;
            Monitor.PulseAll(_condition);
        }

        if (ShowProgress)
        {
            try
            {
                _display.Render(Simulations, force: simulation.IsFinished);
            }
            catch (Exception error)
            {
                Debug.WriteLine($"TRNRun console display failed: {error}");
            }
        }

        Action<Simulation, TrnRunEvent>? handlers = SimulationUpdated;
        if (handlers is not null)
        {
            foreach (Action<Simulation, TrnRunEvent> handler in handlers.GetInvocationList())
            {
                try
                {
                    handler(simulation, runEvent);
                }
                catch (Exception error)
                {
                    Debug.WriteLine($"TRNRun update callback failed: {error}");
                }
            }
        }
    }

    // These helpers are called only while holding _condition; lock order is manager then simulation.
    private bool Finished(Simulation? simulation) =>
        simulation?.IsFinished ?? _simulations.All(item => item.IsFinished);

    private void ValidateOwnership(Simulation? simulation)
    {
        if (simulation is not null &&
            (!_byId.TryGetValue(simulation.Id, out Simulation? owned) || !ReferenceEquals(owned, simulation)))
        {
            throw new ArgumentException("Simulation does not belong to this manager.", nameof(simulation));
        }
    }

    private void ThrowIfClosed() => ObjectDisposedException.ThrowIf(_closed, this);

    private void ThrowIfReaderStopped()
    {
        if (_readerStopped)
        {
            string[] unfinished = _simulations.Where(item => !item.IsFinished).Select(item => item.Id).ToArray();
            string detail = unfinished.Length == 0
                ? "TRNRun queue output stopped."
                : $"TRNRun queue output stopped before accepting or completing run IDs: {string.Join(", ", unfinished)}.";
            throw new IOException(detail, _readerError);
        }
    }

    private void ThrowIfReaderThread()
    {
        if (Environment.CurrentManagedThreadId == Volatile.Read(ref _readerThreadId))
        {
            throw new InvalidOperationException("Submission, blocking manager operations, and shutdown are not allowed from queue callbacks.");
        }
    }
}
