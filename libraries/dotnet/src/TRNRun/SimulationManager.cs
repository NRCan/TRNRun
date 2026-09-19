using System.Globalization;
using System.Runtime.ExceptionServices;
using TRNRun.Display;
using TRNRun.Internal;

namespace TRNRun;

/// <summary>Synchronously submits and monitors simulations through one native TRNRun queue.</summary>
/// <remarks>
/// <para>
/// Use this manager on its creating thread, with only one active operation or Follow enumeration.
/// The native queue owns concurrency. No background reader runs: long pauses between calls or
/// while consuming Follow can fill stdout and stall the queue and its runners.
/// </para>
/// <para>
/// Call <see cref="Shutdown"/> explicitly, normally from a finally block. Waiting does not close
/// the queue. This class does not implement IDisposable; scope exit is not graceful cleanup.
/// </para>
/// </remarks>
public sealed class SimulationManager
{
    private readonly QueueProcess _queue;
    private readonly ConsoleDisplay _display;
    private readonly int _ownerThreadId = Environment.CurrentManagedThreadId;
    private readonly List<Simulation> _simulations = new();
    private readonly Dictionary<string, Simulation> _active = new(StringComparer.Ordinal);
    private long _nextId = 1;
    private bool _operationActive;
    private bool _queueEof;
    private bool _shutdown;
    private bool _submissionFailed;

    /// <summary>Starts a native queue with the specified worker concurrency.</summary>
    /// <param name="maxConcurrent">Positive worker count; defaults to processor count minus one, at least one.</param>
    /// <param name="refreshInterval">Positive display refresh interval; defaults to one second. It does not control pipe reading.</param>
    /// <param name="trnRunQueuePath">An unquoted queue executable path, or null to locate the bundled win-x64 executable.</param>
    /// <exception cref="PlatformNotSupportedException">The host is not Windows.</exception>
    /// <exception cref="ArgumentOutOfRangeException">Concurrency or the refresh interval is not positive.</exception>
    /// <exception cref="ArgumentException">The queue executable path is empty or blank.</exception>
    /// <exception cref="FileNotFoundException">The queue executable cannot be found.</exception>
    public SimulationManager(
        int? maxConcurrent = null,
        TimeSpan? refreshInterval = null,
        string? trnRunQueuePath = null)
    {
        if (!OperatingSystem.IsWindows())
        {
            throw new PlatformNotSupportedException("TRNRun requires Windows.");
        }

        int concurrency = maxConcurrent ?? Math.Max(Environment.ProcessorCount - 1, 1);
        ArgumentOutOfRangeException.ThrowIfLessThan(concurrency, 1, nameof(maxConcurrent));
        _display = new ConsoleDisplay(refreshInterval ?? TimeSpan.FromSeconds(1));

        // An explicit path never falls back to the executable bundled in native/.
        string executable =
            trnRunQueuePath ?? Path.Combine(AppContext.BaseDirectory, "native", "trnrunq.exe");
        ArgumentException.ThrowIfNullOrWhiteSpace(executable, nameof(trnRunQueuePath));

        executable = Path.GetFullPath(executable);
        if (!File.Exists(executable))
        {
            throw new FileNotFoundException($"Queue executable not found: '{executable}'.", executable);
        }

        _queue = new QueueProcess(executable, concurrency);
    }

    /// <summary>Gets or sets whether manager operations render progress to the console. Defaults to false.</summary>
    /// <remarks>Rendering is synchronous and throttled by the constructor's refresh interval.</remarks>
    public bool ShowProgress { get; set; }

    /// <summary>Gets a copy of the accepted simulations in acceptance order.</summary>
    public IReadOnlyList<Simulation> Simulations => _simulations.ToArray();

    /// <summary>Gets finished simulations whose latest status is <see cref="SimulationStatus.Done"/>.</summary>
    public IReadOnlyList<Simulation> Succeeded => _simulations.Where(simulation => simulation.Succeeded).ToArray();

    /// <summary>Gets a copy of finished simulations that did not succeed.</summary>
    public IReadOnlyList<Simulation> Failed =>
        _simulations.Where(simulation => simulation.IsFinished && !simulation.Succeeded).ToArray();

    /// <summary>Submits a deck and blocks until a queue worker accepts it, before runner launch.</summary>
    /// <param name="deckPath">An existing, unquoted .dck or .trd path.</param>
    /// <param name="config">The immutable configuration to validate and submit.</param>
    /// <returns>The accepted simulation, whose state is updated by subsequent manager calls.</returns>
    /// <remarks>
    /// Acceptance means worker pickup, not merely writing to stdin. This call may block while all
    /// workers are occupied, and processes other simulations' events while awaiting acceptance.
    /// Failed writes are not retried because the queue may already have received the request.
    /// </remarks>
    /// <exception cref="ArgumentException">The deck or an executable path is empty, or the deck is not a .dck or .trd file.</exception>
    /// <exception cref="ArgumentOutOfRangeException">A configuration enum value or duration is invalid.</exception>
    /// <exception cref="FileNotFoundException">The deck or a required executable cannot be found.</exception>
    /// <exception cref="IOException">Submission fails or stdout closes with outstanding requests.</exception>
    /// <exception cref="InvalidOperationException">The manager is closed, used from another thread, or already reading output.</exception>
    public Simulation Add(string deckPath, SimulationConfig config)
    {
        EnterOperation();
        try
        {
            if (_submissionFailed)
            {
                throw new InvalidOperationException("A queue write failed. Drain this manager with Shutdown; do not retry submissions.");
            }

            ArgumentNullException.ThrowIfNull(config);
            ArgumentException.ThrowIfNullOrWhiteSpace(deckPath);
            string fullDeckPath = Path.GetFullPath(deckPath);
            if (!File.Exists(fullDeckPath))
            {
                throw new FileNotFoundException($"Deck file not found: '{fullDeckPath}'.", fullDeckPath);
            }

            string extension = Path.GetExtension(fullDeckPath);
            if (!string.Equals(extension, ".dck", StringComparison.OrdinalIgnoreCase)
                && !string.Equals(extension, ".trd", StringComparison.OrdinalIgnoreCase))
            {
                throw new ArgumentException("The deck must be a .dck or .trd file.", nameof(deckPath));
            }

            string[] arguments = config.ToCliArgs(out string runnerPath);
            string id = _nextId.ToString(CultureInfo.InvariantCulture);
            _nextId = checked(_nextId + 1);
            var simulation = new Simulation(id, fullDeckPath, config);

            // Register before writing: a failed flush does not prove the queue missed the request.
            _active.Add(id, simulation);
            try
            {
                _queue.Send(id, fullDeckPath, runnerPath, arguments);
            }
            catch (IOException error)
            {
                _submissionFailed = true;
                throw new IOException($"Could not submit run {id}; delivery is uncertain. Call Shutdown to drain the queue.", error);
            }

            while (!simulation.IsAccepted)
            {
                ReadNextUpdate();
                if (simulation.IsFinished && !simulation.IsAccepted)
                {
                    throw new IOException($"TRNRun queue completed run {id} without reporting ACCEPTED.");
                }
            }

            return simulation;
        }
        finally
        {
            _operationActive = false;
        }
    }

    /// <summary>Blocks until one simulation, or all accepted simulations, receives queue completion.</summary>
    /// <param name="simulation">An accepted simulation owned by this manager, or null for all runs.</param>
    /// <remarks>
    /// Other runs are updated even when selecting one run. An already completed selection returns
    /// immediately. There is no client-side timeout, and the queue remains open for more submissions.
    /// </remarks>
    /// <exception cref="ArgumentException">The selected simulation does not belong to this manager.</exception>
    /// <exception cref="IOException">Queue stdout ends with outstanding requests.</exception>
    public void Wait(Simulation? simulation = null)
    {
        foreach (Simulation _ in Follow(simulation))
        {
        }
    }

    /// <summary>Yields live simulation objects as new native events are consumed, until queue completion.</summary>
    /// <param name="simulation">An accepted simulation owned by this manager, or null to yield all runs' updates.</param>
    /// <returns>A synchronous sequence of the existing, mutable simulation objects, not state snapshots.</returns>
    /// <remarks>
    /// <para>
    /// Events already consumed by Add, Wait, or another enumeration are not replayed. A selected run
    /// filters yields, not event processing: all other runs still update. Completion is determined by
    /// QUEUE/COMPLETED, never by terminal runner status or 100 percent progress alone.
    /// </para>
    /// <para>
    /// Do not interleave enumerations or call other operations while an enumerator is active.
    /// Dispose a manually obtained enumerator when stopping early; foreach does this automatically.
    /// Pausing enumeration pauses pipe reading and can stall native processes.
    /// </para>
    /// </remarks>
    /// <exception cref="ArgumentException">The selected simulation does not belong to this manager.</exception>
    /// <exception cref="InvalidOperationException">The manager is closed, used from another thread, or already reading output.</exception>
    /// <exception cref="IOException">Queue stdout ends with outstanding requests.</exception>
    public IEnumerable<Simulation> Follow(Simulation? simulation = null)
    {
        CheckAvailable();
        ValidateSelection(simulation);
        return FollowCore(simulation);
    }

    /// <summary>Closes queue input, drains all submitted work, waits for queue exit, and releases owned resources.</summary>
    /// <remarks>
    /// <para>
    /// Shutdown drains work rather than cancelling it. It can block indefinitely, especially when
    /// timeout or stall killing is disabled. Call it from a finally block after disposing any active
    /// Follow enumerator. Repeated calls after shutdown are harmless; new operations are not allowed.
    /// </para>
    /// <para>
    /// Unexpected EOF and nonzero queue exit codes are reported without inventing simulation outcomes.
    /// Job Object protection is best-effort and is released along with queue streams and process handles.
    /// If a transport failure makes draining impossible, emergency cleanup attempts to terminate and
    /// reap the process tree; the error is still reported and no completion events are synthesized.
    /// </para>
    /// </remarks>
    /// <exception cref="IOException">The queue closes with outstanding runs, has a transport failure, or exits unsuccessfully.</exception>
    /// <exception cref="InvalidOperationException">The manager is used from another thread or an operation is still active.</exception>
    public void Shutdown()
    {
        CheckThread();
        if (_shutdown)
        {
            return;
        }

        if (_operationActive)
        {
            throw new InvalidOperationException("Finish or dispose the active Follow enumerator before shutting down.");
        }

        _operationActive = true;
        _shutdown = true;
        Exception? failure = null;
        Exception? displayFailure = null;
        try
        {
            try
            {
                _queue.CloseInput();
                while (!_queueEof)
                {
                    Simulation? updated = ReadNextUpdate(render: false);
                    if (displayFailure is null && updated is not null)
                    {
                        try
                        {
                            Render(force: updated.IsFinished);
                        }
                        catch (Exception error)
                        {
                            // Continue draining even when the console is broken; report it after cleanup.
                            displayFailure = error;
                        }
                    }
                }
            }
            catch (Exception error)
            {
                failure = error;
            }

            // Waiting before EOF can deadlock against a full stdout pipe.
            if (_queueEof)
            {
                int exitCode = _queue.WaitForExit();
                if (exitCode != 0)
                {
                    failure = new IOException(
                        $"TRNRun queue exited with code {exitCode}; see inherited queue stderr for details.", failure);
                }
            }
            else
            {
                try
                {
                    _queue.Abort();
                }
                catch (Exception cleanupError)
                {
                    failure = new IOException(
                        "Queue draining and emergency process cleanup failed; native processes may still be running.",
                        failure is null ? cleanupError : new AggregateException(failure, cleanupError));
                }
            }
        }
        finally
        {
            try
            {
                _queue.Release();
            }
            finally
            {
                _operationActive = false;
            }
        }

        if (failure is not null)
        {
            ExceptionDispatchInfo.Capture(failure).Throw();
        }

        if (displayFailure is not null)
        {
            ExceptionDispatchInfo.Capture(displayFailure).Throw();
        }

        Render(force: true);
    }

    private IEnumerable<Simulation> FollowCore(Simulation? selected)
    {
        EnterOperation();
        try
        {
            while (_active.Count > 0 && selected?.IsFinished != true)
            {
                Simulation? updated = ReadNextUpdate();
                if (updated is not null && (selected is null || ReferenceEquals(selected, updated)))
                {
                    yield return updated;
                }
            }
        }
        finally
        {
            _operationActive = false;
        }
    }

    private Simulation? ReadNextUpdate(bool render = true)
    {
        while (true)
        {
            string? line = _queue.ReadLine();
            if (line is null)
            {
                _queueEof = true;
                if (_active.Count > 0)
                {
                    throw new IOException(
                        $"TRNRun queue closed before accepting or completing run IDs: {string.Join(", ", _active.Keys)}.");
                }

                return null;
            }

            TrnRunEvent? runEvent = EventParser.Parse(line);
            if (runEvent is null || !_active.TryGetValue(runEvent.RunId, out Simulation? simulation))
            {
                continue;
            }

            if (runEvent is QueueEvent queueEvent)
            {
                switch (queueEvent.Status)
                {
                    case "ACCEPTED" when !simulation.IsAccepted:
                        _simulations.Add(simulation);
                        break;
                    case "COMPLETED":
                        _active.Remove(simulation.Id);
                        break;
                    default:
                        continue;
                }
            }

            simulation.Apply(runEvent);
            if (render)
            {
                Render(force: simulation.IsFinished);
            }

            return simulation;
        }
    }

    private void Render(bool force = false)
    {
        if (ShowProgress)
        {
            _display.Render(_simulations, force);
        }
    }

    private void ValidateSelection(Simulation? simulation)
    {
        if (simulation is not null && !_simulations.Contains(simulation))
        {
            throw new ArgumentException("Simulation does not belong to this manager.", nameof(simulation));
        }
    }

    private void CheckThread()
    {
        if (Environment.CurrentManagedThreadId != _ownerThreadId)
        {
            throw new InvalidOperationException("Use SimulationManager only on the thread that created it.");
        }
    }

    private void CheckAvailable()
    {
        CheckThread();
        if (_shutdown || _queueEof)
        {
            throw new InvalidOperationException("The queue is closed. Call Shutdown to release any remaining resources.");
        }

        if (_operationActive)
        {
            throw new InvalidOperationException("Only one manager operation or Follow enumeration can read the queue at a time.");
        }
    }

    private void EnterOperation()
    {
        CheckAvailable();
        _operationActive = true;
    }
}
