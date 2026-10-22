using System.ComponentModel;
using System.Globalization;
using System.IO;

namespace TRNRun.GuiExample;

/// <summary>One run in the runs table, replaced by each snapshot trnrund saves.</summary>
/// <param name="info">The run's first snapshot.</param>
public sealed class RunRow(SimulationInfo info) : INotifyPropertyChanged
{
    private SimulationInfo _info = info;

    /// <inheritdoc/>
    public event PropertyChangedEventHandler? PropertyChanged;

    /// <summary>Number trnrund assigned the run.</summary>
    public long RunId => _info.RunId;

    /// <summary>Label the run was added with, or its deck name.</summary>
    public string Label => _info.Label ?? Path.GetFileNameWithoutExtension(_info.DeckFile);

    /// <summary>Absolute deck path.</summary>
    public string DeckFile => _info.DeckFile;

    /// <summary>Daemon lifecycle state.</summary>
    public SimulationState State => _info.State;

    /// <summary>Whether the run will not change again.</summary>
    public bool IsFinished => _info.IsFinished;

    /// <summary>The run's state with its outcome, for coloring.</summary>
    public RunKind Kind => _info.State switch
    {
        SimulationState.Queued => RunKind.Queued,
        SimulationState.Running => RunKind.Running,
        _ when _info.Succeeded == true => RunKind.Succeeded,
        _ when _info.Status == SimulationStatus.Cancelled => RunKind.Cancelled,
        _ => RunKind.Failed,
    };

    /// <summary>Status badge text; a failure is named by TRNRun's status, such as Timeout.</summary>
    public string StatusText => Kind switch
    {
        RunKind.Queued => "Queued",
        RunKind.Running => _info.Status == SimulationStatus.Launching ? "Launching" : "Running",
        RunKind.Succeeded => "Done",
        RunKind.Cancelled => "Cancelled",
        _ => _info.Status is { } status and not SimulationStatus.Done ? status.ToString() : "Failed",
    };

    /// <summary>Completion from 0 to 100; a run that succeeded without reporting progress is 100.</summary>
    public double Percent => _info.Progress is { } progress ? progress.Percent * 100 : Kind == RunKind.Succeeded ? 100 : 0;

    /// <summary>Completion as text, or empty when unknown.</summary>
    public string PercentText => _info.Progress is not null || Kind == RunKind.Succeeded ? $"{Percent:0} %" : "";

    /// <summary>Whether the run is running without reporting progress, as without Type3830.</summary>
    public bool IsIndeterminate => State == SimulationState.Running && _info.Progress is null;

    /// <summary>Simulated time reached, out of the stop time when known.</summary>
    public string SimTimeText => _info.Progress is { } progress
        ? _info.Config is { } config ? $"{progress.Time:N0} / {config.Stop:N0} h" : $"{progress.Time:N0} h"
        : "";

    /// <summary>Wall-clock time since the run started, until it finished.</summary>
    public string ElapsedText => _info.StartedAt is { } started
        ? Duration((_info.FinishedAt ?? DateTimeOffset.UtcNow) - started)
        : "";

    /// <summary>TRNRun's estimate of the time left, while running.</summary>
    public string EtaText => State == SimulationState.Running && _info.Progress is { Eta: var eta }
        ? Duration(eta)
        : "";

    /// <summary>Warning log entries saved so far.</summary>
    public int Warnings => _info.Warnings;

    /// <summary>Fatal log entries saved so far.</summary>
    public int Fatals => _info.Fatals;

    /// <summary>Why a run failed or was cancelled, else TRNRun's latest status message.</summary>
    public string Detail => Kind is RunKind.Failed or RunKind.Cancelled && !string.IsNullOrEmpty(_info.Error)
        ? _info.Error
        : _info.StatusMessage ?? "";

    /// <summary>Replaces the run's snapshot and refreshes every column.</summary>
    public void Update(SimulationInfo info)
    {
        _info = info;
        Changed(string.Empty);
    }

    /// <summary>Refreshes the elapsed time of a running run between snapshots.</summary>
    public void Tick() => Changed(nameof(ElapsedText));

    /// <summary>Raises <see cref="PropertyChanged"/>; an empty name refreshes every property.</summary>
    private void Changed(string property) => PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(property));

    /// <summary>Formats a duration as m:ss, or h:mm:ss from one hour.</summary>
    private static string Duration(TimeSpan time)
    {
        time = time < TimeSpan.Zero ? TimeSpan.Zero : time;
        return time.ToString(time.TotalHours >= 1 ? @"h\:mm\:ss" : @"m\:ss", CultureInfo.InvariantCulture);
    }
}
