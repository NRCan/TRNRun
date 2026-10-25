// Example: a window that runs decks through trnrund and shows their progress and logs live.
// Usage: TRNRun.GuiExample [deck.dck | deck-directory]...
// Without arguments, it runs 10 copies of the example deck.

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Win32;

namespace TRNRun.GuiExample;

/// <summary>Adds decks to one trnrund, then polls its runs and logs; every daemon call is awaited on the UI thread.</summary>
public partial class MainWindow : Window
{
    private static readonly TimeSpan PollInterval = TimeSpan.FromMilliseconds(500);

    // Refreshes the running times between polls.
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly ICollectionView _logView;
    // Cancelled when the window closes, to stop polling the daemon.
    private readonly CancellationTokenSource _closing = new();
    private HashSet<long> _selected = [];
    private TRNRunDaemon? _daemon;
    private Task? _polling;
    private bool _adding;
    private bool _stopping;

    /// <summary>Fills the settings with defaults; trnrund is not started yet.</summary>
    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;

        TrnexeBox.Text = new[] { @"C:\TRNSYS18\Exe\TrnEXE64.exe", @"C:\TRNSYS17\Exe\TrnEXE64.exe" }
            .FirstOrDefault(File.Exists) ?? "";
        for (int count = 1; count <= Environment.ProcessorCount; count++)
        {
            WorkersBox.Items.Add(count);
        }

        WorkersBox.SelectedItem = Math.Max(Environment.ProcessorCount - 1, 1);

        _logView = CollectionViewSource.GetDefaultView(Logs);
        _logView.Filter = ShowsLog;
        _clock.Tick += OnClockTick;
        Loaded += OnLoaded;
    }

    /// <summary>The runs added in this window, in the order they were added.</summary>
    public ObservableCollection<RunRow> Runs { get; } = [];

    /// <summary>Their log entries, oldest first per run; the log table filters them.</summary>
    public ObservableCollection<LogRow> Logs { get; } = [];

    /// <summary>Adds the decks and deck directories given on the command line, or else copies of the example deck.</summary>
    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        string[] paths = Environment.GetCommandLineArgs()[1..];
        await AddAsync(paths.Length > 0 ? paths.SelectMany(DecksIn) : CopyExampleDeck(10));
    }

    /// <summary>Copies the example deck <paramref name="count"/> times into runs/ beside the application, one per run, since TRNSYS writes its outputs beside the deck.</summary>
    private static string[] CopyExampleDeck(int count)
    {
        string master = Path.Combine(AppContext.BaseDirectory, "dck", "slow_wo_plot_w_tracking.dck");
        string runs = Directory.CreateDirectory(Path.Combine(AppContext.BaseDirectory, "runs")).FullName;
        string[] decks = Enumerable.Range(1, count)
            .Select(i => Path.Combine(runs, $"{Path.GetFileNameWithoutExtension(master)}_{i:000}.dck"))
            .ToArray();
        foreach (string deck in decks)
        {
            File.Copy(master, deck, overwrite: true);
        }

        return decks;
    }

    /// <summary>Adds the decks picked in a file dialog.</summary>
    private async void OnAddDecks(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "Add decks", Filter = "TRNSYS decks (*.dck)|*.dck", Multiselect = true };
        if (dialog.ShowDialog(this) == true)
        {
            await AddAsync(dialog.FileNames);
        }
    }

    /// <summary>Adds every deck in the folder picked in a folder dialog.</summary>
    private async void OnAddFolder(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Add every deck in a folder" };
        if (dialog.ShowDialog(this) == true)
        {
            await AddAsync(DecksIn(dialog.FolderName));
        }
    }

    /// <summary>Accepts dragged files and folders.</summary>
    private void OnDragOver(object sender, DragEventArgs e)
    {
        e.Effects = e.Data.GetDataPresent(DataFormats.FileDrop) && !_adding ? DragDropEffects.Copy : DragDropEffects.None;
        e.Handled = true;
    }

    /// <summary>Adds the dropped decks, and every deck in the dropped folders.</summary>
    private async void OnDrop(object sender, DragEventArgs e)
    {
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths)
        {
            await AddAsync(paths.SelectMany(DecksIn));
        }
    }

    /// <summary>Returns the decks in a folder, sorted by name, or the path itself if it is a deck.</summary>
    private static IEnumerable<string> DecksIn(string path)
    {
        if (Directory.Exists(path))
        {
            return Directory.GetFiles(path, "*.dck").Order(StringComparer.OrdinalIgnoreCase);
        }

        return path.EndsWith(".dck", StringComparison.OrdinalIgnoreCase) ? [path] : [];
    }

    /// <summary>Starts trnrund if needed, then submits each deck; reports the decks it refused.</summary>
    private async Task AddAsync(IEnumerable<string> paths)
    {
        if (_adding)
        {
            return;
        }

        string[] decks = paths.ToArray();
        if (decks.Length == 0)
        {
            ShowError("No decks", "There are no .dck files there.");
            return;
        }

        if (ReadSettings() is not { } settings)
        {
            return;
        }

        SetAdding(true);
        try
        {
            _daemon ??= await StartDaemonAsync();
            if (_daemon is not { } daemon)
            {
                return;
            }

            List<string> refused = await SubmitAsync(daemon, decks, settings);
            if (refused.Count > 0)
            {
                ShowError("Some decks were not added", string.Join(Environment.NewLine, refused));
            }
        }
        catch (OperationCanceledException) when (_closing.IsCancellationRequested)
        {
            // The window is closing.
        }
        catch (Exception error) when (error is TRNRunException or IOException)
        {
            ShowError("Could not add the decks", error.Message);
        }
        finally
        {
            SetAdding(false);
        }
    }

    /// <summary>Returns the run settings, or <see langword="null"/> after reporting a missing TRNSYS.</summary>
    private SimulationSettings? ReadSettings()
    {
        string trnexe = TrnexeBox.Text.Trim();
        if (trnexe.Length > 0 && !File.Exists(trnexe))
        {
            ShowError("TRNSYS not found", $"There is no TRNSYS executable at {trnexe}.");
            return null;
        }

        return new SimulationSettings
        {
            TrnexePath = trnexe.Length > 0 ? trnexe : null,
            GuiVisibility = ShowTrnsysBox.IsChecked == true ? GuiVisibility.AutoClose : GuiVisibility.Hidden,
            WatchLog = true,
            WatchTmp = TrackProgressBox.IsChecked == true,
        };
    }

    /// <summary>Starts and polls trnrund with the chosen number of workers, or returns <see langword="null"/> after reporting why not.</summary>
    private async Task<TRNRunDaemon?> StartDaemonAsync()
    {
        int workers = (int)WorkersBox.SelectedItem;
        SessionText.Text = "Starting trnrund…";
        TRNRunDaemon daemon;
        try
        {
            daemon = await TRNRunDaemon.StartAsync(workers, cancellationToken: _closing.Token);
        }
        catch (Exception error) when (error is TRNRunException or IOException)
        {
            SessionText.Text = "trnrund is not running.";
            ShowError("Could not start trnrund", error.Message);
            return null;
        }

        WorkersBox.IsEnabled = false;
        SessionText.Text = $"trnrund running {workers} simulations at once";
        _polling = PollAsync(daemon, _closing.Token);
        _clock.Start();
        return daemon;
    }

    /// <summary>Submits each deck and shows its row at once, returning a line for each deck trnrund refused.</summary>
    private async Task<List<string>> SubmitAsync(TRNRunDaemon daemon, IEnumerable<string> decks, SimulationSettings settings)
    {
        var refused = new List<string>();
        foreach (string deck in decks)
        {
            try
            {
                long simId = await daemon.AddAsync(deck, settings, Path.GetFileNameWithoutExtension(deck), _closing.Token);
                Runs.Add(new RunRow(await daemon.GetSimulationAsync(simId, cancellationToken: _closing.Token)));
            }
            catch (RequestException error)
            {
                refused.Add($"{Path.GetFileName(deck)}: {error.Message}");
            }
        }

        UpdateSummary();
        return refused;
    }

    /// <summary>Disables adding while decks are being submitted.</summary>
    private void SetAdding(bool adding)
    {
        _adding = adding;
        AddDecksButton.IsEnabled = !adding;
        AddFolderButton.IsEnabled = !adding;
    }

    /// <summary>Refreshes the runs and their logs every <see cref="PollInterval"/>, until the window closes or trnrund stops.</summary>
    private async Task PollAsync(TRNRunDaemon daemon, CancellationToken cancellationToken)
    {
        try
        {
            while (true)
            {
                await Task.Delay(PollInterval, cancellationToken);
                await RefreshAsync(daemon, cancellationToken);
                UpdateSummary();
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // The window is closing.
        }
        catch (TRNRunException error)
        {
            _clock.Stop();
            SessionText.Text = "trnrund stopped.";
            ShowError("trnrund stopped", error.Message);
        }
    }

    /// <summary>Updates the unfinished rows, reading a run's logs only when it has new ones; a finished row never changes again.</summary>
    private async Task RefreshAsync(TRNRunDaemon daemon, CancellationToken cancellationToken)
    {
        // Two requests cover every unfinished run, without logs.
        var unfinished = new Dictionary<long, Simulation>();
        foreach (SimulationState state in new[] { SimulationState.Queued, SimulationState.Running })
        {
            foreach (Simulation sim in await daemon.GetSimulationsAsync(state, cancellationToken: cancellationToken))
            {
                unfinished[sim.SimId] = sim;
            }
        }

        // A copy: decks added while this awaits add rows.
        foreach (RunRow row in Runs.Where(row => !row.IsFinished).ToArray())
        {
            // Missing from both lists, it has finished (or moved on between the two requests): read it with its logs.
            if (!unfinished.TryGetValue(row.SimId, out Simulation? sim) || sim.Notices + sim.Warnings + sim.Fatals > row.LogsShown)
            {
                sim = await daemon.GetSimulationAsync(row.SimId, withLogs: true, cancellationToken);
                foreach (LogEvent log in sim.Logs.Skip(row.LogsShown))
                {
                    Logs.Add(new LogRow(log, row.SimId, row.Label));
                }

                row.LogsShown = sim.Logs.Count;
            }

            row.Update(sim);
        }
    }

    /// <summary>Refreshes the elapsed time of running runs between polls.</summary>
    private void OnClockTick(object? sender, EventArgs e)
    {
        foreach (RunRow row in Runs.Where(row => row.State == SimulationState.Running))
        {
            row.Tick();
        }
    }

    /// <summary>Refreshes the overall progress and the run counts.</summary>
    private void UpdateSummary()
    {
        int queued = Runs.Count(row => row.State == SimulationState.Queued);
        int running = Runs.Count(row => row.State == SimulationState.Running);
        int succeeded = Runs.Count(row => row.Kind == RunKind.Succeeded);
        int finished = Runs.Count - queued - running;

        OverallProgress.Maximum = Math.Max(Runs.Count, 1);
        OverallProgress.Value = finished;
        OverallText.Text = $"{finished} of {Runs.Count} finished";
        SummaryText.Text = $"{queued} queued · {running} running · {succeeded} succeeded · {finished - succeeded} failed or cancelled";
    }

    /// <summary>Shows the logs of the selected runs, or of every run when none is selected.</summary>
    private void OnRunSelectionChanged(object sender, SelectionChangedEventArgs e)
    {
        RunRow[] selected = RunsGrid.SelectedItems.Cast<RunRow>().ToArray();
        _selected = selected.Select(row => row.SimId).ToHashSet();
        LogTitle.Text = selected.Length switch
        {
            0 => "Log · all runs",
            1 => $"Log · {selected[0].Label}",
            _ => $"Log · {selected.Length} runs",
        };
        _logView.Refresh();
    }

    /// <summary>Applies the notice filter.</summary>
    private void OnLogFilterChanged(object sender, RoutedEventArgs e) => _logView.Refresh();

    /// <summary>Whether the log table shows an entry.</summary>
    private bool ShowsLog(object item) =>
        item is LogRow log
        && (ShowNoticesBox.IsChecked == true || log.Severity != LogSeverity.Notice)
        && (_selected.Count == 0 || _selected.Contains(log.SimId));

    /// <summary>Shows the double-clicked run's deck in Explorer.</summary>
    private void OnRunDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source
            && ItemsControl.ContainerFromElement(RunsGrid, source) is DataGridRow { Item: RunRow row })
        {
            Process.Start("explorer.exe", $"/select,\"{row.DeckFile}\"");
        }
    }

    /// <summary>Cancels the selected runs that have not finished.</summary>
    private async void OnCancelSelected(object sender, RoutedEventArgs e) =>
        await CancelAsync(RunsGrid.SelectedItems.Cast<RunRow>());

    /// <summary>Cancels every unfinished run, after asking.</summary>
    private async void OnCancelAll(object sender, RoutedEventArgs e)
    {
        int unfinished = Runs.Count(row => !row.IsFinished);
        if (unfinished > 0 && Ask("Cancel all", $"Cancel {unfinished} unfinished runs?"))
        {
            await CancelAsync(Runs);
        }
    }

    /// <summary>Asks trnrund to cancel the unfinished runs among <paramref name="rows"/>.</summary>
    private async Task CancelAsync(IEnumerable<RunRow> rows)
    {
        long[] simIds = rows.Where(row => !row.IsFinished).Select(row => row.SimId).ToArray();
        if (_daemon is not { } daemon || simIds.Length == 0)
        {
            return;
        }

        try
        {
            foreach (long simId in simIds)
            {
                await daemon.CancelAsync(simId, _closing.Token);
            }
        }
        catch (OperationCanceledException) when (_closing.IsCancellationRequested)
        {
            // The window is closing, which interrupts every run anyway.
        }
        catch (TRNRunException error)
        {
            ShowError("Could not cancel", error.Message);
        }
    }

    /// <summary>Picks the TRNSYS executable.</summary>
    private void OnBrowseTrnexe(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "TRNSYS executable", Filter = "TRNSYS (TrnEXE*.exe)|TrnEXE*.exe|Programs (*.exe)|*.exe" };
        if (dialog.ShowDialog(this) == true)
        {
            TrnexeBox.Text = dialog.FileName;
        }
    }

    /// <summary>Asks before interrupting unfinished runs, then stops trnrund before closing.</summary>
    protected override void OnClosing(CancelEventArgs e)
    {
        base.OnClosing(e);
        if (_stopping)
        {
            e.Cancel = true;
            return;
        }

        if (_daemon is null)
        {
            return;
        }

        int unfinished = Runs.Count(row => !row.IsFinished);
        e.Cancel = true;
        if (unfinished == 0 || Ask("Close TRNRun", $"{unfinished} runs have not finished. Interrupt them and close?"))
        {
            _ = StopAndCloseAsync();
        }
    }

    /// <summary>Stops trnrund, interrupting unfinished runs, then closes the window.</summary>
    private async Task StopAndCloseAsync()
    {
        _stopping = true;
        _clock.Stop();
        IsEnabled = false;
        SessionText.Text = "Stopping trnrund…";

        await _closing.CancelAsync();
        if (_polling is not null)
        {
            await _polling;
        }

        TRNRunDaemon daemon = _daemon!;
        _daemon = null;
        await daemon.DisposeAsync();

        _stopping = false;
        Close();
    }

    /// <summary>Shows an error message.</summary>
    private void ShowError(string title, string message) =>
        MessageBox.Show(this, message, title, MessageBoxButton.OK, MessageBoxImage.Error);

    /// <summary>Asks a yes-or-no question.</summary>
    private bool Ask(string title, string question) =>
        MessageBox.Show(this, question, title, MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;
}
