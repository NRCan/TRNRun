using System.Diagnostics;
using System.Globalization;
using System.Text.Json;
using TRNRun.Display;
using TRNRun.Internal;

namespace TRNRun;

/// <summary>Submits and monitors simulations synchronously through one queue process.</summary>
/// <remarks>
/// Not thread-safe; use one operation or Follow enumeration at a time.
/// State advances only while calls read stdout; pausing can fill the pipe and stall the queue.
/// Call <see cref="Shutdown"/> explicitly, usually in a finally block; Wait does not close the queue.
/// Premature EOF is an error; no recovery or simulation outcomes are synthesized.
/// Display errors propagate. Call Shutdown only once; operations after shutdown are unsupported.
/// </remarks>
public sealed class SimulationManager
{
    private readonly QueueProcess _queue;
    private readonly ConsoleDisplay _display;
    private readonly List<Simulation> _simulations = new();
    private readonly Dictionary<string, Simulation> _active = new(StringComparer.Ordinal);
    private long _nextId = 1;
    private bool _queueEof;

    /// <summary>Starts the queue process and configures progress rendering.</summary>
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
        _queue = new QueueProcess(Path.GetFullPath(executable), concurrency);
    }

    /// <summary>Gets or sets whether to render console progress during manager calls; defaults to false.</summary>
    public bool ShowProgress { get; set; }

    /// <summary>Gets a copy of queue-accepted simulations in acceptance order.</summary>
    public IReadOnlyList<Simulation> Simulations => _simulations.ToArray();

    /// <summary>Gets a copy of simulations that completed successfully.</summary>
    public IReadOnlyList<Simulation> Succeeded => _simulations.Where(simulation => simulation.Succeeded).ToArray();

    /// <summary>Gets a copy of finished simulations that did not succeed.</summary>
    public IReadOnlyList<Simulation> Failed =>
        _simulations.Where(simulation => simulation.IsFinished && !simulation.Succeeded).ToArray();

    /// <summary>Submits a deck and blocks until a queue worker accepts it, before runner launch.</summary>
    /// <remarks>
    /// Processes other runs' events while waiting for an available worker.
    /// Validates the deck file and configuration before sending. Write errors propagate without retry.
    /// </remarks>
    public Simulation Add(string deckPath, SimulationConfig config)
    {
        string fullDeckPath = Path.GetFullPath(deckPath);
        if (!File.Exists(fullDeckPath))
        {
            throw new FileNotFoundException($"Deck file not found: '{fullDeckPath}'.", fullDeckPath);
        }

        string[] arguments = config.ToCliArgs(out string runnerPath);
        string id = _nextId.ToString(CultureInfo.InvariantCulture);
        _nextId++;
        var simulation = new Simulation(id, fullDeckPath, config);

        _queue.Send(new QueueRequest(
            RunId: id,
            DeckFile: fullDeckPath,
            RunnerPath: runnerPath,
            RunnerArgs: arguments));
        _active.Add(id, simulation);

        while (!simulation.IsAccepted)
        {
            ReadNextUpdate();
        }

        return simulation;
    }

    /// <summary>Reads queue output until the selected simulation, or all accepted simulations, finish.</summary>
    /// <remarks>
    /// The selection must belong to this manager; other runs still update.
    /// Already-finished runs return immediately. There is no client-side timeout.
    /// </remarks>
    public void Wait(Simulation? simulation = null)
    {
        foreach (Simulation _ in Follow(simulation))
        {
        }
    }

    /// <summary>Yields updates for the selected simulation, or all simulations when omitted.</summary>
    /// <remarks>
    /// The selection must belong to this manager. All runs still update; past events are not replayed.
    /// Yields live objects, not snapshots, until QUEUE/COMPLETED.
    /// Validation and reading begin when enumerated.
    /// </remarks>
    public IEnumerable<Simulation> Follow(Simulation? simulation = null)
    {
        if (simulation is not null && !_simulations.Contains(simulation))
        {
            throw new ArgumentException("Simulation does not belong to this manager.", nameof(simulation));
        }

        while (_active.Count > 0 && simulation?.IsFinished != true)
        {
            Simulation? updated = ReadNextUpdate();
            if (updated is null)
            {
                yield break;
            }

            if (simulation is null || ReferenceEquals(simulation, updated))
            {
                yield return updated;
            }
        }
    }

    /// <summary>Drains submitted work, waits for queue exit, and releases resources.</summary>
    /// <remarks>
    /// Drains rather than cancels and may block indefinitely. Call only once, after finishing other operations.
    /// Reports EOF and exit failures. Display and read errors propagate without recovery.
    /// </remarks>
    public void Shutdown()
    {
        int exitCode = 0;
        using (_queue)
        {
            _queue.CloseInput();
            try
            {
                while (!_queueEof && ReadNextUpdate() is not null)
                {
                }
            }
            finally
            {
                // Waiting before EOF can deadlock against a full stdout pipe.
                if (_queueEof)
                {
                    exitCode = _queue.WaitForExit();
                }
            }
        }

        // Preserve an already reported premature-EOF error during cleanup.
        if (exitCode != 0 && _active.Count == 0)
        {
            throw new IOException($"TRNRun queue exited with code {exitCode}; see queue stderr for details.");
        }
    }

    /// <summary>Reads and applies the next update; EOF is normal only with no outstanding runs.</summary>
    private Simulation? ReadNextUpdate()
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

            TrnRunEvent? runEvent;
            try
            {
                runEvent = EventParser.Parse(line);
            }
            catch (JsonException error)
            {
                Debug.WriteLine($"Dropped malformed queue line: {line}\n{error}");
                continue;
            }
            if (runEvent is null || !_active.TryGetValue(runEvent.RunId, out Simulation? simulation))
            {
                continue;
            }

            switch (runEvent)
            {
                case QueueEvent { Status: "ACCEPTED" } when !simulation.IsAccepted:
                    simulation.MarkAccepted();
                    _simulations.Add(simulation);
                    break;

                case QueueEvent { Status: "COMPLETED" } completion:
                    _active.Remove(simulation.Id);
                    simulation.MarkCompleted(completion);
                    break;

                case QueueEvent:
                    continue;

                default:
                    simulation.ApplyRunnerEvent(runEvent);
                    break;
            }

            if (ShowProgress)
            {
                _display.Render(_simulations, force: simulation.IsFinished);
            }

            return simulation;
        }
    }
}
