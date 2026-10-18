// Example: a window that runs decks through trnrund and shows their progress and logs live.
//
// Usage: TRNRun.GuiExample [deck.dck | deck-directory]...
// Decks given on the command line are added once the window opens, with the default settings.
// trnrund starts with the first deck added, so the database and concurrency chosen then stay
// until the window closes. Closing it interrupts unfinished runs, after asking.

using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Threading;
using Microsoft.Data.Sqlite;
using Microsoft.Win32;

namespace TRNRun.GuiExample;

/// <summary>Adds decks to one trnrund, then shows its runs and logs as it saves them.</summary>
/// <remarks>
/// A loop on the UI thread awaits the daemon's changes and reads them through the window's own
/// connection; each await resumes on the UI thread, so it updates the rows directly. Every call
/// to the daemon is awaited, so none blocks the window.
/// </remarks>
public partial class MainWindow : Window
{
    private readonly Dictionary<long, RunRow> _rows = [];
    // Refreshes the running times between changes.
    private readonly DispatcherTimer _clock = new() { Interval = TimeSpan.FromMilliseconds(250) };
    private readonly ICollectionView _logView;
    // Cancelled when the window closes, to stop following the daemon.
    private readonly CancellationTokenSource _closing = new();
    private HashSet<long> _selected = [];
    private Daemon? _daemon;
    private SqliteConnection? _connection;
    private Task? _following;
    // Where the next read of the database starts.
    private ChangePosition _position;
    private bool _adding;
    private bool _stopping;

    /// <summary>Fills the settings with defaults; trnrund is not started yet.</summary>
    public MainWindow()
    {
        InitializeComponent();
        DataContext = this;

        TrnexeBox.Text = new[] { @"C:\TRNSYS18\Exe\TrnEXE64.exe", @"C:\TRNSYS17\Exe\TrnEXE64.exe" }
            .FirstOrDefault(File.Exists) ?? "";
        DatabaseBox.Text = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments), "TRNRun", "runs.sqlite3");
        for (int count = 1; count <= Environment.ProcessorCount; count++)
        {
            MaxConcurrentBox.Items.Add(count);
        }

        MaxConcurrentBox.SelectedItem = Math.Max(Environment.ProcessorCount - 1, 1);

        _logView = CollectionViewSource.GetDefaultView(Logs);
        _logView.Filter = ShowsLog;
        _clock.Tick += OnClockTick;
        Loaded += OnLoaded;
    }

    /// <summary>This session's runs, in the order they were added.</summary>
    public ObservableCollection<RunRow> Runs { get; } = [];

    /// <summary>This session's log entries, oldest first; the log table filters them.</summary>
    public ObservableCollection<LogRow> Logs { get; } = [];

    // -----------------------------------------------------------------
    // Adding decks
    // -----------------------------------------------------------------

    /// <summary>Adds the decks and deck directories given on the command line, if any.</summary>
    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        string[] paths = Environment.GetCommandLineArgs()[1..];
        if (paths.Length > 0)
        {
            await AddAsync(paths.SelectMany(DecksIn));
        }
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
    /// <remarks>The rows appear once the queued runs are read from the database.</remarks>
    private async Task AddAsync(IEnumerable<string> paths)
    {
        string[] decks = paths.ToArray();
        if (_adding)
        {
            return;
        }

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
        catch (Exception error) when (error is TrnrunException or IOException or TimeoutException)
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

    /// <summary>Starts trnrund with the chosen database and concurrency, which then stay fixed, and starts following it.</summary>
    /// <returns>The daemon, or <see langword="null"/> after reporting why it did not start.</returns>
    private async Task<Daemon?> StartDaemonAsync()
    {
        string database = DatabaseBox.Text.Trim();
        var options = new DaemonOptions
        {
            DatabasePath = database.Length > 0 ? database : null,
            MaxConcurrent = (int)MaxConcurrentBox.SelectedItem,
        };
        SessionText.Text = "Starting trnrund…";
        Daemon? daemon = null;
        try
        {
            if (options.DatabasePath is not null)
            {
                // trnrund creates the database but not its folder.
                Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(options.DatabasePath))!);
            }

            daemon = await Daemon.StartAsync(options, _closing.Token);
            _connection = daemon.OpenDatabase();
        }
        catch (Exception error) when (error is TrnrunException or SqliteException or IOException or UnauthorizedAccessException or TimeoutException)
        {
            if (daemon is not null)
            {
                await daemon.DisposeAsync();
            }

            SessionText.Text = "trnrund is not running.";
            ShowError("Could not start trnrund", error.Message);
            return null;
        }

        DatabaseBox.IsEnabled = false;
        BrowseDatabaseButton.IsEnabled = false;
        MaxConcurrentBox.IsEnabled = false;
        SessionText.Text = $"Session {daemon.SessionId} · {daemon.DatabasePath}";
        // Only this session's runs are shown, even in a reused database.
        _position = daemon.StartPosition;
        _following = FollowAsync(daemon, _connection, _closing.Token);
        _clock.Start();
        return daemon;
    }

    /// <summary>Submits each deck, returning a line for each one trnrund refused.</summary>
    private async Task<List<string>> SubmitAsync(Daemon daemon, IEnumerable<string> decks, SimulationSettings settings)
    {
        var refused = new List<string>();
        foreach (string deck in decks)
        {
            try
            {
                await daemon.AddAsync(deck, settings, Path.GetFileNameWithoutExtension(deck), _closing.Token);
            }
            catch (RequestRejectedException error)
            {
                refused.Add($"{Path.GetFileName(deck)}: {error.Message}");
            }
        }

        return refused;
    }

    /// <summary>Disables adding while decks are being submitted.</summary>
    private void SetAdding(bool adding)
    {
        _adding = adding;
        AddDecksButton.IsEnabled = !adding;
        AddFolderButton.IsEnabled = !adding;
    }

    // -----------------------------------------------------------------
    // Following the runs
    // -----------------------------------------------------------------

    /// <summary>Shows what trnrund saves, as it saves it, until the window closes or trnrund stops.</summary>
    private async Task FollowAsync(Daemon daemon, SqliteConnection connection, CancellationToken cancellationToken)
    {
        try
        {
            while (true)
            {
                // Throws once trnrund ended and everything it saved was read.
                await daemon.WaitForChangesAsync(_position.Revision, cancellationToken);
                Show(connection.ReadChanges(_position));
                UpdateSummary();
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            // The window is closing.
        }
        catch (TrnrunException error)
        {
            _clock.Stop();
            SessionText.Text = "trnrund stopped.";
            ShowError("trnrund stopped", error.Message);
        }
    }

    /// <summary>Refreshes the elapsed time of running runs between changes.</summary>
    private void OnClockTick(object? sender, EventArgs e)
    {
        foreach (RunRow row in Runs.Where(row => row.State == SimulationState.Running))
        {
            row.Tick();
        }
    }

    /// <summary>Adds or updates the changed runs' rows and appends the new log entries.</summary>
    private void Show(Changes changes)
    {
        _position = changes.Next;
        foreach (SimulationInfo run in changes.Runs)
        {
            if (_rows.TryGetValue(run.RunId, out RunRow? row))
            {
                row.Update(run);
            }
            else
            {
                // Runs added together arrive in the order they last changed; keep them by number.
                row = new RunRow(run);
                _rows.Add(run.RunId, row);
                int index = Runs.Count;
                while (index > 0 && Runs[index - 1].RunId > row.RunId)
                {
                    index--;
                }

                Runs.Insert(index, row);
            }
        }

        foreach (LogEvent log in changes.Logs)
        {
            Logs.Add(new LogRow(log, _rows.TryGetValue(log.RunId, out RunRow? row) ? row.Label : $"#{log.RunId}"));
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
        _selected = selected.Select(row => row.RunId).ToHashSet();
        LogTitle.Text = selected.Length switch
        {
            0 => "Log · all runs",
            1 => $"Log · {selected[0].Label}",
            _ => $"Log · {selected.Length} runs",
        };
        _logView.Refresh();
    }

    /// <summary>Applies the notice filter.</summary>
    private void OnLogFilterChanged(object sender, RoutedEventArgs e) => _logView?.Refresh();

    /// <summary>Whether the log table shows an entry.</summary>
    private bool ShowsLog(object item) =>
        item is LogRow log
        && (ShowNoticesBox.IsChecked == true || log.Severity != LogSeverity.Notice)
        && (_selected.Count == 0 || _selected.Contains(log.RunId));

    /// <summary>Shows the double-clicked run's deck in Explorer.</summary>
    private void OnRunDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (e.OriginalSource is DependencyObject source
            && ItemsControl.ContainerFromElement(RunsGrid, source) is DataGridRow { Item: RunRow row })
        {
            Process.Start("explorer.exe", $"/select,\"{row.DeckFile}\"");
        }
    }

    // -----------------------------------------------------------------
    // Cancelling
    // -----------------------------------------------------------------

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
        long[] runIds = rows.Where(row => !row.IsFinished).Select(row => row.RunId).ToArray();
        if (_daemon is not { } daemon || runIds.Length == 0)
        {
            return;
        }

        try
        {
            foreach (long runId in runIds)
            {
                await daemon.CancelAsync(runId, _closing.Token);
            }
        }
        catch (OperationCanceledException) when (_closing.IsCancellationRequested)
        {
            // The window is closing, which interrupts every run anyway.
        }
        catch (Exception error) when (error is TrnrunException or TimeoutException)
        {
            ShowError("Could not cancel", error.Message);
        }
    }

    // -----------------------------------------------------------------
    // Settings and closing
    // -----------------------------------------------------------------

    /// <summary>Picks the TRNSYS executable.</summary>
    private void OnBrowseTrnexe(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "TRNSYS executable", Filter = "TRNSYS (TrnEXE*.exe)|TrnEXE*.exe|Programs (*.exe)|*.exe" };
        if (dialog.ShowDialog(this) == true)
        {
            TrnexeBox.Text = dialog.FileName;
        }
    }

    /// <summary>Picks a new or existing database.</summary>
    private void OnBrowseDatabase(object sender, RoutedEventArgs e)
    {
        var dialog = new SaveFileDialog
        {
            Title = "Database",
            Filter = "SQLite databases (*.sqlite3)|*.sqlite3",
            FileName = "runs.sqlite3",
            OverwritePrompt = false,
        };
        if (dialog.ShowDialog(this) == true)
        {
            DatabaseBox.Text = dialog.FileName;
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

        // Stop reading first; then the connection closes, before the daemon deletes a temporary database.
        await _closing.CancelAsync();
        if (_following is not null)
        {
            await _following;
        }

        _connection?.Dispose();
        _connection = null;
        Daemon daemon = _daemon!;
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
