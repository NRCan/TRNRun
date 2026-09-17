using System;
using System.Collections.Generic;

namespace TRNRun;

/// <summary>Holds the current event state of one simulation submitted through the native queue.</summary>
/// <remarks>
/// State changes only while the owning manager pumps queue output on the calling thread. This type
/// is not thread-safe. Individual events are immutable, and log history is returned as a copy.
/// A terminal runner status does not finish a simulation until queue completion is received.
/// </remarks>
public sealed class Simulation
{
    /// <summary>The default maximum number of retained log entries.</summary>
    public const int DefaultMaxLogEvents = 5000;

    private readonly Queue<LogEvent> _logs = new();
    private readonly Dictionary<string, long> _severityCounts = new(StringComparer.OrdinalIgnoreCase);

    internal Simulation(string id, string deckPath, SimulationConfig config)
        : this(id, deckPath, config, DefaultMaxLogEvents)
    {
    }

    internal Simulation(string id, string deckPath, SimulationConfig config, int maxLogEvents)
    {
        ArgumentException.ThrowIfNullOrEmpty(id);
        ArgumentException.ThrowIfNullOrEmpty(deckPath);
        ArgumentNullException.ThrowIfNull(config);
        ArgumentOutOfRangeException.ThrowIfNegative(maxLogEvents);

        Id = id;
        DeckPath = deckPath;
        Config = config;
        MaxLogEvents = maxLogEvents;
    }

    /// <summary>Gets the opaque, case-sensitive queue request identifier.</summary>
    public string Id { get; }

    /// <summary>Gets the deck path submitted by the manager.</summary>
    public string DeckPath { get; }

    /// <summary>Gets the immutable configuration submitted for this simulation.</summary>
    public SimulationConfig Config { get; }

    /// <summary>Gets whether a queue worker has accepted this simulation.</summary>
    public bool IsAccepted { get; private set; }

    /// <summary>Gets whether the queue has reported COMPLETED after all runner output.</summary>
    public bool IsFinished => CompletionEvent is not null;

    /// <summary>Gets whether the simulation is still waiting or running, including before acceptance.</summary>
    public bool IsRunning => !IsFinished;

    /// <summary>Gets whether the latest runner status is an exact canonical terminal value.</summary>
    /// <remarks>The recognized values are DONE, ERROR, CANCELLED, TIMEOUT, and STALLED.</remarks>
    public bool HasTerminalStatus => Status?.Status is "DONE" or "ERROR" or "CANCELLED" or "TIMEOUT" or "STALLED";

    /// <summary>Gets whether queue completion was received and the latest runner status is exactly DONE.</summary>
    /// <remarks>
    /// Exit codes and progress do not determine success. Missing or differently cased status strings
    /// do not count as DONE, even when the runner exits with code zero.
    /// </remarks>
    public bool Succeeded => IsFinished && Status?.Status == "DONE";

    /// <summary>Gets the latest runner status event, or <see langword="null"/> before one is received.</summary>
    public StatusEvent? Status { get; private set; }

    /// <summary>Gets the latest progress event, or <see langword="null"/> before one is received.</summary>
    public ProgressEvent? Progress { get; private set; }

    /// <summary>Gets the latest native simulation bounds, or <see langword="null"/> before they are received.</summary>
    public ConfigEvent? ConfigEvent { get; private set; }

    /// <summary>Gets the latest effective runner settings, or <see langword="null"/> before they are received.</summary>
    public SettingEvent? SettingEvent { get; private set; }

    /// <summary>Gets the queue's COMPLETED event, or <see langword="null"/> while the run is unfinished.</summary>
    /// <remarks>
    /// A missing completion event differs from a completion event whose exit code is
    /// <see langword="null"/>: the latter can indicate that the runner could not be launched.
    /// </remarks>
    public QueueEvent? CompletionEvent { get; private set; }

    /// <summary>Gets the maximum retained log count; zero retains no log history.</summary>
    /// <remarks>This limit does not affect cumulative log counters.</remarks>
    public int MaxLogEvents { get; }

    /// <summary>Gets a copy of retained log entries in oldest-first order.</summary>
    /// <remarks>Changing or retaining the returned collection does not change this simulation's history.</remarks>
    public IReadOnlyList<LogEvent> Logs => _logs.ToArray();

    /// <summary>Gets the total received log count, including unknown severities and evicted entries.</summary>
    public long LogCount { get; private set; }

    /// <summary>Gets the cumulative notice count, matching severity names case-insensitively.</summary>
    public long Notices => _severityCounts.GetValueOrDefault("notice");

    /// <summary>Gets the cumulative warning count, matching severity names case-insensitively.</summary>
    public long Warnings => _severityCounts.GetValueOrDefault("warning");

    /// <summary>Gets the cumulative fatal count, matching severity names case-insensitively.</summary>
    public long Fatals => _severityCounts.GetValueOrDefault("fatal");

    /// <summary>Folds a routed event into the state without synthesizing runner outcomes.</summary>
    internal void Apply(TrnRunEvent runEvent)
    {
        ArgumentNullException.ThrowIfNull(runEvent);
        if (IsFinished || !string.Equals(runEvent.RunId, Id, StringComparison.Ordinal))
        {
            return;
        }

        switch (runEvent)
        {
            case QueueEvent { Status: "ACCEPTED" }:
                IsAccepted = true;
                break;
            case QueueEvent { Status: "COMPLETED" } completion:
                CompletionEvent = completion;
                break;
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
                if (MaxLogEvents > 0)
                {
                    if (_logs.Count == MaxLogEvents)
                    {
                        _logs.Dequeue();
                    }

                    _logs.Enqueue(log);
                }

                _severityCounts[log.Severity] = _severityCounts.GetValueOrDefault(log.Severity) + 1;
                LogCount++;
                break;
        }
    }
}
