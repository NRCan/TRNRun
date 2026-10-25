// Example: the least a WPF window needs to run decks through trnrund and show them live.
// See TRNRun.GuiExample for a fuller window.

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.IO;
using System.Windows;
using Microsoft.Win32;

namespace TRNRun.SimpleGuiExample;

/// <summary>Starts trnrund with the window, polls it on the UI thread, and stops it on close.</summary>
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
    private TRNRunDaemon? _daemon;
    private Task _polling = Task.CompletedTask;

    /// <summary>Binds the runs table to <see cref="Runs"/>.</summary>
    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;
    }

    /// <summary>Every run, latest snapshot of each, by simId.</summary>
    public ObservableCollection<Simulation> Runs { get; } = [];

    /// <summary>Starts trnrund, then polls it.</summary>
    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        try
        {
            _daemon = await TRNRunDaemon.StartAsync();
        }
        catch (Exception error)
        {
            MessageBox.Show(this, error.Message, "Could not start trnrund");
            Close();
            return;
        }

        _polling = PollAsync(_daemon);
    }

    /// <summary>Copies every run's latest snapshot into the table twice a second, until the window closes or trnrund stops.</summary>
    private async Task PollAsync(TRNRunDaemon daemon)
    {
        try
        {
            while (true)
            {
                // In lifecycle order, so a run that moves on between two requests keeps its later snapshot.
                // shortcut: re-reads every finished run each poll; release runs you stop showing, or poll as TRNRun.GuiExample does, for hundreds of runs.
                foreach (SimulationState state in Enum.GetValues<SimulationState>())
                {
                    foreach (Simulation sim in await daemon.GetSimulationsAsync(state))
                    {
                        int index = Runs.ToList().FindIndex(row => row.SimId == sim.SimId);
                        if (index < 0)
                        {
                            Runs.Insert(Runs.Count(row => row.SimId < sim.SimId), sim);
                        }
                        else
                        {
                            Runs[index] = sim;
                        }
                    }
                }

                await Task.Delay(TimeSpan.FromMilliseconds(500), _closing.Token);
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

    /// <summary>Submits the decks picked in a file dialog; their rows appear at the next poll.</summary>
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
            catch (TRNRunException error)
            {
                MessageBox.Show(this, error.Message, $"Could not add {Path.GetFileName(deck)}");
            }
        }
    }

    /// <summary>Shows the clicked row's log entries so far; click again for newer ones.</summary>
    private async void OnShowLogs(object sender, RoutedEventArgs e)
    {
        if (_daemon is not null && sender is FrameworkElement { DataContext: Simulation run })
        {
            try
            {
                LogsGrid.ItemsSource = (await _daemon.GetSimulationAsync(run.SimId, withLogs: true)).Logs;
                LogsTitle.Text = $"Logs of #{run.SimId} {run.Label}";
            }
            catch (TRNRunException error)
            {
                MessageBox.Show(this, error.Message, "Could not read the logs");
            }
        }
    }

    /// <summary>Cancels the run of the clicked row; a finished run is left unchanged.</summary>
    private async void OnCancel(object sender, RoutedEventArgs e)
    {
        if (_daemon is not null && sender is FrameworkElement { DataContext: Simulation run })
        {
            try
            {
                await _daemon.CancelAsync(run.SimId);
            }
            catch (TRNRunException error)
            {
                MessageBox.Show(this, error.Message, "Could not cancel");
            }
        }
    }

    /// <summary>Stops polling, then stops trnrund, interrupting unfinished runs, before closing.</summary>
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
        await _polling;
        await daemon.DisposeAsync();
        _daemon = null;
        Close();
    }
}
