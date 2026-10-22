// Example: the least a WPF window needs to run decks through trnrund and show them live.
// See TRNRun.GuiExample for a fuller window.

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using Microsoft.Win32;

namespace TRNRun.SimpleGuiExample;

/// <summary>Starts trnrund with the window, follows it on the UI thread, and stops it on close.</summary>
public partial class MainWindow : Window
{
    // Set TrnexePath if TRNRun cannot find TRNSYS. WatchTmp reports progress, but needs Type3830 in the deck.
    private static readonly SimulationSettings Settings = new()
    {
        WatchLog = true,
        WatchTmp = true,
        Severity = LogSeverity.Warning, // TRNRun's default, Notice, buries warnings under notices.
    };

    private readonly CancellationTokenSource _closing = new();
    private Daemon? _daemon;
    private Task _following = Task.CompletedTask;

    /// <summary>Binds the tables to <see cref="Runs"/> and <see cref="Logs"/>.</summary>
    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
    }

    /// <summary>This session's runs, latest snapshot of each.</summary>
    public ObservableCollection<SimulationInfo> Runs { get; } = [];

    /// <summary>This session's log entries, oldest first.</summary>
    public ObservableCollection<LogEvent> Logs { get; } = [];

    /// <summary>Starts trnrund, then follows it.</summary>
    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            // Kept after the window closes, for your own SQL; a reused file keeps its earlier runs, but only this session's are shown.
            _daemon = await Daemon.StartAsync(new DaemonOptions { DatabasePath = "runs.sqlite3" });
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "Could not start trnrund");
            Close();
            return;
        }

        _following = FollowAsync(_daemon);
    }

    /// <summary>Copies each change trnrund saves into the tables, until the window closes or trnrund stops.</summary>
    private async Task FollowAsync(Daemon daemon)
    {
        try
        {
            await foreach (Changes changes in daemon.FollowAsync(_closing.Token))
            {
                foreach (SimulationInfo run in changes.Runs)
                {
                    // shortcut: scans every row per changed run; keep a Dictionary<long, int> of RunId to index for hundreds of runs.
                    int index = Runs.ToList().FindIndex(row => row.RunId == run.RunId);
                    if (index < 0)
                    {
                        Runs.Add(run);
                    }
                    else
                    {
                        Runs[index] = run;
                    }
                }

                foreach (LogEvent log in changes.Logs)
                {
                    Logs.Add(log);
                }
            }
        }
        catch (OperationCanceledException) when (_closing.IsCancellationRequested)
        {
            // The window is closing.
        }
        catch (Exception error)
        {
            // Such as DaemonExitedException when trnrund crashed.
            MessageBox.Show(this, error.Message, "trnrund stopped");
        }
    }

    /// <summary>Submits the decks picked in a file dialog; their rows appear once trnrund saves them.</summary>
    private async void OnAddDecks(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Filter = "TRNSYS decks (*.dck)|*.dck", Multiselect = true };
        if (_daemon is null || dialog.ShowDialog(this) != true)
        {
            return;
        }

        foreach (string deck in dialog.FileNames)
        {
            try
            {
                await _daemon.AddAsync(deck, Settings, Path.GetFileNameWithoutExtension(deck));
            }
            catch (TrnrunException error)
            {
                MessageBox.Show(this, error.Message, $"Could not add {Path.GetFileName(deck)}");
            }
        }
    }

    /// <summary>Cancels the run of the clicked row; a finished run is left unchanged.</summary>
    private async void OnCancel(object sender, RoutedEventArgs e)
    {
        if (_daemon is not null && sender is FrameworkElement { DataContext: SimulationInfo run })
        {
            try
            {
                await _daemon.CancelAsync(run.RunId);
            }
            catch (TrnrunException error)
            {
                MessageBox.Show(this, error.Message, "Could not cancel");
            }
        }
    }

    /// <summary>Stops following, then stops trnrund, interrupting unfinished runs, before closing.</summary>
    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        if (_daemon is not { } daemon)
        {
            return;
        }

        e.Cancel = true;
        if (_closing.IsCancellationRequested)
        {
            return; // Already stopping.
        }

        IsEnabled = false;
        await _closing.CancelAsync();
        await _following; // Leaving the loop closes its connection, so the temporary database can be deleted.
        await daemon.DisposeAsync();
        _daemon = null;
        Close();
    }
}
