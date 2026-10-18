using System.Diagnostics;
using System.Text.Json;
using Microsoft.Data.Sqlite;

namespace TRNRun.Tests;

/// <summary>Tests for <see cref="Daemon"/>: driving the bundled trnrund and knowing when its database changed.</summary>
/// <remarks>The daemon is real; TRNRun is TRNRun.FakeTrnrun replaying decks from <see cref="Decks.Write"/>.</remarks>
public sealed class DaemonTests : IDisposable
{
    /// <summary>How long any run gets to reach the state a test waits for.</summary>
    internal static readonly TimeSpan Timeout = TimeSpan.FromSeconds(30);

    private readonly TempDirectory _temp = new();
    private readonly List<Daemon> _started = [];

    /// <summary>Closes every daemon started, then deletes the temporary directory.</summary>
    public void Dispose()
    {
        foreach (Daemon daemon in _started)
        {
            daemon.Dispose();
        }

        _temp.Dispose();
    }

    /// <summary>Options for the fake TRNRun, by default with a temporary database and two slots.</summary>
    internal static DaemonOptions Options(string? databasePath = null, int maxConcurrent = 2) =>
        new() { DatabasePath = databasePath, MaxConcurrent = maxConcurrent, TrnrunPath = Executables.FakeTrnrun };

    /// <summary>Starts a daemon with <see cref="Options"/>.</summary>
    private Daemon Start(string? databasePath = null, int maxConcurrent = 2) => Track(Daemon.Start(Options(databasePath, maxConcurrent)));

    /// <summary>Disposes <paramref name="daemon"/> after the test.</summary>
    private Daemon Track(Daemon daemon)
    {
        _started.Add(daemon);
        return daemon;
    }

    /// <summary>Returns a run's current row through a connection of its own.</summary>
    internal static SimulationInfo? GetRun(Daemon daemon, long runId)
    {
        using SqliteConnection connection = daemon.OpenDatabase();
        return TestDatabase.FetchRun(connection, runId);
    }

    /// <summary>Waits for the daemon's changes until run <paramref name="runId"/> satisfies <paramref name="done"/>, and returns it.</summary>
    internal static SimulationInfo WaitUntil(Daemon daemon, long runId, Func<SimulationInfo, bool> done)
    {
        var elapsed = Stopwatch.StartNew();
        using SqliteConnection connection = daemon.OpenDatabase();
        while (elapsed.Elapsed < Timeout)
        {
            // Read before the run, so a save in between wakes the next wait at once.
            long revision = TestDatabase.LatestRevision(connection);
            SimulationInfo? info = TestDatabase.FetchRun(connection, runId);
            if (info is not null && done(info))
            {
                return info;
            }

            daemon.WaitForChanges(revision, TimeSpan.FromMilliseconds(500));
        }

        throw new TimeoutException($"Run {runId} did not reach the expected state within {Timeout.TotalSeconds} s");
    }

    /// <summary>Whether the run finished.</summary>
    internal static bool Finished(SimulationInfo info) => info.IsFinished;

    /// <summary>Whether the run is running.</summary>
    internal static bool Running(SimulationInfo info) => info.State == SimulationState.Running;

    // -----------------------------------------------------------------
    // Reply fields
    // -----------------------------------------------------------------

    /// <summary>Read reply fields that have the expected type.</summary>
    [Fact]
    public void ReplyFieldsOfTheExpectedType()
    {
        using JsonDocument reply = JsonDocument.Parse("""{"ok":true,"runId":3,"databasePath":"C:\\runs.sqlite3"}""");

        Assert.Equal(3, Daemon.ReplyInt64(reply.RootElement, "runId"));
        Assert.Equal(@"C:\runs.sqlite3", Daemon.ReplyString(reply.RootElement, "databasePath"));
    }

    /// <summary>Report a reply trnrund should not have sent as a protocol error.</summary>
    [Theory]
    [InlineData("""{"ok":true}""")]
    [InlineData("""{"ok":true,"runId":"3"}""")]
    [InlineData("""{"ok":true,"runId":3.5}""")]
    public void ReplyFieldRejectsAMissingOrMistypedValue(string json)
    {
        using JsonDocument reply = JsonDocument.Parse(json);

        var error = Assert.Throws<TrnrunException>(() => Daemon.ReplyInt64(reply.RootElement, "runId"));
        Assert.Contains("trnrund reply has no integer 'runId'", error.Message);
    }

    // -----------------------------------------------------------------
    // Starting and closing
    // -----------------------------------------------------------------

    /// <summary>Default to the executables bundled beside the application, and a temporary database.</summary>
    [Fact]
    public void OptionsDefaultToTheBundledExecutables()
    {
        var options = new DaemonOptions();

        Assert.Equal(Path.Combine(AppContext.BaseDirectory, "native", "trnrund.exe"), options.TrnrundPath);
        Assert.Equal(Path.Combine(AppContext.BaseDirectory, "native", "trnrun.exe"), options.TrnrunPath);
        Assert.Equal((null, null, TimeSpan.FromSeconds(60)), (options.DatabasePath, options.MaxConcurrent, options.RequestTimeout));
    }

    /// <summary>Report a missing trnrund executable by its path.</summary>
    [Fact]
    public void MissingTrnrundFailsToStart()
    {
        var error = Assert.Throws<FileNotFoundException>(
            () => Daemon.Start(new DaemonOptions { DatabasePath = _temp.File("runs.sqlite3"), TrnrundPath = _temp.File("trnrund.exe") }));
        Assert.Contains("trnrund executable not found", error.Message);
    }

    /// <summary>Keep the runs in a temporary database, deleted with the daemon.</summary>
    [Fact]
    public void TemporaryDatabaseIsDeletedOnDispose()
    {
        Daemon daemon = Start();

        Assert.True(File.Exists(daemon.DatabasePath));
        Assert.Equal((1L, default(ChangePosition)), (daemon.SessionId, daemon.StartPosition));
        daemon.Dispose();
        daemon.Dispose(); // Safe more than once.

        Assert.False(Directory.Exists(Path.GetDirectoryName(daemon.DatabasePath)));
    }

    /// <summary>Continue an existing database in a new session, without losing its runs.</summary>
    [Fact]
    public void GivenDatabaseIsKeptAndContinued()
    {
        string path = _temp.File("runs.sqlite3");
        string deck = Decks.Write(_temp.File("model.dck"));
        long firstRun;
        using (Daemon first = Start(path))
        {
            firstRun = first.Add(deck);
            WaitUntil(first, firstRun, Finished);
            first.Shutdown();
        }

        Assert.True(File.Exists(path));

        using Daemon second = Start(path);
        using SqliteConnection connection = second.OpenDatabase();
        Assert.Equal(path, second.DatabasePath);
        Assert.Equal(2, second.SessionId);
        Assert.True(second.StartPosition.Revision > 0);
        Assert.Equal(3, second.StartPosition.LogId);
        Assert.True(connection.ReadChanges(second.StartPosition).IsEmpty); // Only new changes.

        long secondRun = second.Add(deck);

        Assert.Equal(firstRun + 1, secondRun);
        Assert.Equal(firstRun, TestDatabase.Execute(connection, "SELECT run_id FROM runs WHERE session_id = 1"));
        Assert.True(second.WaitForChanges(second.StartPosition.Revision, Timeout));
        Assert.Equal([secondRun], connection.ReadChanges(second.StartPosition).Runs.Select(info => info.RunId));
    }

    /// <summary>Throw trnrund's startup error, such as a database held by another daemon.</summary>
    [Fact]
    public void DatabaseInUseFailsWithTrnrundMessage()
    {
        string path = _temp.File("runs.sqlite3");
        Start(path);

        var error = Assert.Throws<DaemonExitedException>(() => Start(path));
        Assert.Contains("in use by another trnrund", error.Message);
    }

    /// <summary>Save unfinished runs as interrupted when leaving the using block.</summary>
    [Fact]
    public void DisposeInterruptsUnfinishedRuns()
    {
        string path = _temp.File("runs.sqlite3");
        string deck = Decks.Write(_temp.File("gate.dck"), gated: true);
        long runId;
        using (Daemon daemon = Start(path))
        {
            runId = daemon.Add(deck);
            WaitUntil(daemon, runId, Running);
        }

        using SqliteConnection connection = TrnrunDatabase.Open(path);
        SimulationInfo? info = TestDatabase.FetchRun(connection, runId);

        Assert.NotNull(info);
        Assert.True(info.IsFinished);
        Assert.Equal((SimulationStatus.Cancelled, "Interrupted"), (info.Status, info.StatusMessage));
        Assert.Equal("Interrupted: the client disconnected", info.Error);
    }

    /// <summary>Throw ObjectDisposedException from every member that talks to trnrund once disposed.</summary>
    [Fact]
    public async Task MembersThrowObjectDisposedExceptionAfterDispose()
    {
        Daemon daemon = Start();
        string deck = Decks.Write(_temp.File("model.dck"));
        await daemon.DisposeAsync();

        Assert.Throws<ObjectDisposedException>(() => daemon.Add(deck));
        Assert.Throws<ObjectDisposedException>(() => daemon.Cancel(1));
        Assert.Throws<ObjectDisposedException>(() => daemon.Shutdown());
        Assert.Throws<ObjectDisposedException>(() => daemon.WaitForChanges(0, TimeSpan.Zero));
        Assert.Throws<ObjectDisposedException>(() => daemon.OpenDatabase());
        await Assert.ThrowsAsync<ObjectDisposedException>(() => daemon.AddAsync(deck));
        await Assert.ThrowsAsync<ObjectDisposedException>(() => daemon.WaitForChangesAsync(0));
        Assert.False(File.Exists(daemon.DatabasePath));
    }

    /// <summary>Wake a waiter blocked when the daemon is disposed, rather than leave it hanging.</summary>
    [Fact]
    public async Task DisposeWakesAWaiterWithClosedException()
    {
        Daemon daemon = Start();
        Task waiting = daemon.WaitForChangesAsync(daemon.StartPosition.Revision);

        daemon.Dispose();

        await Assert.ThrowsAsync<ClosedException>(() => waiting.WaitAsync(Timeout));
    }

    // -----------------------------------------------------------------
    // Asynchronous use
    // -----------------------------------------------------------------

    /// <summary>Start, add, follow, shut down and dispose without blocking.</summary>
    [Fact]
    public async Task AsynchronousMembersFollowARunToSuccess()
    {
        await using Daemon daemon = await Daemon.StartAsync(Options());
        using SqliteConnection connection = daemon.OpenDatabase();

        long runId = await daemon.AddAsync(Decks.Write(_temp.File("model.dck")), new SimulationSettings { PollMs = 10 }, label: "async");

        ChangePosition position = daemon.StartPosition;
        SimulationInfo? finished = null;
        using var timeout = new CancellationTokenSource(Timeout);
        while (finished is null)
        {
            await daemon.WaitForChangesAsync(position.Revision, timeout.Token);
            Changes changes = connection.ReadChanges(position);
            position = changes.Next;
            finished = changes.Runs.FirstOrDefault(run => run.RunId == runId && run.IsFinished);
        }

        await daemon.ShutdownAsync(cancellationToken: timeout.Token);

        Assert.Equal((true, "async", 3), (finished.Succeeded, finished.Label, finished.Notices + finished.Warnings + finished.Fatals));
        await Assert.ThrowsAsync<ClosedException>(() => daemon.WaitForChangesAsync(position.Revision));
    }

    /// <summary>Cancel a queued run without blocking.</summary>
    [Fact]
    public async Task CancelAsyncFinishesAQueuedRun()
    {
        Daemon daemon = Start(maxConcurrent: 1);
        await daemon.AddAsync(Decks.Write(_temp.File("gate.dck"), gated: true)); // Holds the only slot.
        long queuedId = await daemon.AddAsync(Decks.Write(_temp.File("model.dck")));

        await daemon.CancelAsync(queuedId);

        SimulationInfo? queued = GetRun(daemon, queuedId);
        Assert.Equal((SimulationStatus.Cancelled, "Not started"), (queued?.Status, queued?.StatusMessage));
        await Assert.ThrowsAsync<RequestRejectedException>(() => daemon.CancelAsync(999));
    }

    /// <summary>Close trnrund when a shutdown is cancelled, saving running runs as interrupted.</summary>
    [Fact]
    public async Task CancelledShutdownAsyncInterruptsRunningRuns()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("gate.dck"), gated: true));
        WaitUntil(daemon, runId, Running);
        using var cancel = new CancellationTokenSource(TimeSpan.FromMilliseconds(200));

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => daemon.ShutdownAsync(cancellationToken: cancel.Token));

        SimulationInfo? info = GetRun(daemon, runId);
        Assert.NotNull(info);
        Assert.True(info.IsFinished);
        Assert.Equal("Interrupted: the client disconnected", info.Error);
    }

    /// <summary>Close trnrund and throw when starting is cancelled.</summary>
    [Fact]
    public async Task CancelledStartAsyncThrows()
    {
        using var cancel = new CancellationTokenSource();
        await cancel.CancelAsync();

        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Daemon.StartAsync(Options(), cancel.Token));
    }

    // -----------------------------------------------------------------
    // Adding runs
    // -----------------------------------------------------------------

    /// <summary>Report a run's events, logs and outcome as trnrund saves them.</summary>
    [Fact]
    public void AddedRunIsFollowedToSuccess()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("model.dck")), ["--pollMs:10"], label: "baseline");

        SimulationInfo info = WaitUntil(daemon, runId, Finished);

        Assert.True(info.Succeeded);
        Assert.Equal((0, null), (info.ExitCode, info.Error));
        Assert.Equal("baseline", info.Label);
        Assert.Equal(daemon.SessionId, info.SessionId);
        Assert.Equal(["--pollMs:10"], info.TrnrunArgs);
        Assert.Equal(_temp.File("model.dck"), info.DeckFile);
        Assert.Equal((SimulationStatus.Done, ""), (info.Status, info.StatusMessage)); // TRNRun sent an empty message.
        Assert.Equal(10.0, info.Config?.Stop);
        Assert.Equal(1.0, info.Progress?.Percent);
        Assert.Equal((1, 1, 1), (info.Notices, info.Warnings, info.Fatals));
        Assert.NotNull(info.SubmittedAt);
        Assert.NotNull(info.StartedAt);
        Assert.NotNull(info.FinishedAt);
        using SqliteConnection connection = daemon.OpenDatabase();
        LogEvent[] logs = connection.ReadChanges().Logs.Where(log => log.RunId == runId).ToArray();
        Assert.Equal(
            [(LogSeverity.Notice, "first"), (LogSeverity.Warning, "second"), (LogSeverity.Fatal, "third")],
            logs.Select(log => (log.Severity, log.Message)));
        Assert.Equal((7L, 56L, 123L, "details"), (logs[1].UnitId, logs[1].TypeId, logs[1].MessageCode, logs[1].Information));
    }

    /// <summary>Hand out each saved change once, ending with the finished run and all its logs.</summary>
    [Fact]
    public void WaitForChangesAndReadChangesReturnEveryChangeOnce()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("model.dck")));
        var runs = new List<SimulationInfo>();
        var logIds = new List<long>();
        ChangePosition position = daemon.StartPosition;
        var elapsed = Stopwatch.StartNew();
        using (SqliteConnection connection = daemon.OpenDatabase())
        {
            while (!(runs.Count > 0 && runs[^1].IsFinished) && elapsed.Elapsed < Timeout)
            {
                if (daemon.WaitForChanges(position.Revision, TimeSpan.FromMilliseconds(500)))
                {
                    Changes changes = connection.ReadChanges(position);
                    position = changes.Next;
                    runs.AddRange(changes.Runs);
                    logIds.AddRange(changes.Logs.Select(log => log.LogId));
                }
            }

            Assert.True(connection.ReadChanges(position).IsEmpty);
        }

        Assert.Equal(runId, runs[^1].RunId);
        Assert.True(runs[^1].IsFinished);
        Assert.Equal(runs.Select(info => info.Revision).Distinct().Order(), runs.Select(info => info.Revision));
        Assert.Equal([1, 2, 3], logIds);
        Assert.False(daemon.WaitForChanges(position.Revision, TimeSpan.FromMilliseconds(100)));
    }

    /// <summary>Keep TRNRun's ERROR status and exit code for a failed run.</summary>
    [Fact]
    public void FailedRunIsReported()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("failed.dck"), Decks.FailedEvents, exitCode: 1));

        SimulationInfo info = WaitUntil(daemon, runId, Finished);

        Assert.False(info.Succeeded);
        Assert.Equal(1, info.ExitCode);
        Assert.Equal((SimulationStatus.Error, "Fake failure"), (info.Status, info.StatusMessage));
    }

    /// <summary>Give a run that exits without a terminal status a daemon-owned ERROR.</summary>
    [Fact]
    public void RunWithoutTerminalStatusIsAnError()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("silent.dck"), []));

        SimulationInfo info = WaitUntil(daemon, runId, Finished);

        Assert.False(info.Succeeded);
        Assert.Equal(0, info.ExitCode);
        Assert.Equal((SimulationStatus.Error, "TRNRun exited without a terminal status"), (info.Status, info.StatusMessage));
    }

    /// <summary>Keep SimulationSettings flags accepted by TRNRun's parser inside trnrund.</summary>
    [Fact]
    public void EverySimulationSettingIsAccepted()
    {
        Daemon daemon = Start();
        var settings = new SimulationSettings
        {
            TrnexePath = Executables.FakeTrnrun,
            GuiVisibility = GuiVisibility.Hidden,
            WaitForGui = false,
            WaitForLst = false,
            WaitForTmp = false,
            DetectTimeoutMs = 1_000,
            ExtraDelayMs = 0,
            PollMs = 10,
            WatchLog = true,
            WatchTmp = true,
            WatchTimeoutMs = 5_000,
            StallTimeoutMs = 3_000,
            CleanOnSuccess = false,
            KillOnTimeout = true,
            KillOnStall = true,
            Severity = LogSeverity.Warning,
            WriteEvents = false,
        };

        long runId = daemon.Add(Decks.Write(_temp.File("model.dck")), settings);

        Assert.Equal(settings.ToCliArgs(), GetRun(daemon, runId)?.TrnrunArgs);
    }

    /// <summary>Accept every window behavior and severity keyword this package writes.</summary>
    [Fact]
    public void EveryEnumKeywordIsAccepted()
    {
        Daemon daemon = Start();
        string deck = Decks.Write(_temp.File("model.dck"));

        foreach (GuiVisibility visibility in Enum.GetValues<GuiVisibility>())
        {
            daemon.Add(deck, new SimulationSettings { GuiVisibility = visibility });
        }

        foreach (LogSeverity severity in Enum.GetValues<LogSeverity>())
        {
            daemon.Add(deck, new SimulationSettings { Severity = severity });
        }
    }

    /// <summary>Reject a run trnrund or TRNRun would refuse, when it is added.</summary>
    [Theory]
    [InlineData("missing.dck", "", "Deck file not found")]
    [InlineData("model.txt", "", "Expected .dck or .trd")]
    [InlineData("model.dck", "--bogus:1", "Unknown option")]
    [InlineData("model.dck", "--pollMs:fast", "Invalid value")]
    [InlineData("model.dck", "--runId:3", "not allowed")]
    [InlineData("model.dck", "extra", "Unexpected argument")]
    public void InvalidRunIsRejected(string deckName, string arg, string message)
    {
        Decks.Write(_temp.File("model.dck"));
        Decks.Write(_temp.File("model.txt"));
        Daemon daemon = Start();

        var error = Assert.Throws<RequestRejectedException>(
            () => daemon.Add(_temp.File(deckName), arg.Length == 0 ? [] : [arg]));

        Assert.Contains(message, error.Message);
        using SqliteConnection connection = daemon.OpenDatabase();
        Assert.Equal(0L, TestDatabase.Execute(connection, "SELECT count(*) FROM runs"));
    }

    // -----------------------------------------------------------------
    // Cancelling
    // -----------------------------------------------------------------

    /// <summary>Finish a queued run on return, and a running one once it is killed.</summary>
    [Fact]
    public void CancelQueuedAndRunningRuns()
    {
        Daemon daemon = Start(maxConcurrent: 1);
        long runningId = daemon.Add(Decks.Write(_temp.File("gate.dck"), gated: true));
        long queuedId = daemon.Add(Decks.Write(_temp.File("model.dck")));
        WaitUntil(daemon, runningId, Running);

        daemon.Cancel(queuedId);

        SimulationInfo? queued = GetRun(daemon, queuedId);
        Assert.NotNull(queued);
        Assert.True(queued.IsFinished);
        Assert.Null(queued.StartedAt);
        Assert.Equal((SimulationStatus.Cancelled, "Not started"), (queued.Status, queued.StatusMessage));
        Assert.Equal("Not started: cancelled by the client", queued.Error);

        daemon.Cancel(runningId);
        SimulationInfo cancelled = WaitUntil(daemon, runningId, Finished);

        Assert.Equal((SimulationStatus.Cancelled, "Interrupted"), (cancelled.Status, cancelled.StatusMessage));
        Assert.Equal("Interrupted: cancelled by the client", cancelled.Error);
        Assert.False(cancelled.Succeeded);
    }

    /// <summary>Keep a finished run's real outcome.</summary>
    [Fact]
    public void CancelLeavesAFinishedRunUnchanged()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("model.dck")));
        SimulationInfo before = WaitUntil(daemon, runId, Finished);

        daemon.Cancel(runId);

        SimulationInfo? after = GetRun(daemon, runId);
        Assert.NotNull(after);
        Assert.Equal(before.Revision, after.Revision);
        Assert.True(after.Succeeded);
    }

    /// <summary>Reject a run ID trnrund never assigned.</summary>
    [Fact]
    public void CancelUnknownRunIsRejected()
    {
        Daemon daemon = Start();

        var error = Assert.Throws<RequestRejectedException>(() => daemon.Cancel(999));
        Assert.Contains("999", error.Message);
    }

    // -----------------------------------------------------------------
    // Shutting down
    // -----------------------------------------------------------------

    /// <summary>Let a running run finish, never start a queued one, then exit cleanly.</summary>
    [Fact]
    public void ShutdownWaitsForRunningRunsAndCancelsQueuedOnes()
    {
        Daemon daemon = Start(maxConcurrent: 1);
        string gate = Decks.Write(_temp.File("gate.dck"), gated: true);
        long runningId = daemon.Add(gate);
        long queuedId = daemon.Add(Decks.Write(_temp.File("model.dck")));
        WaitUntil(daemon, runningId, Running);
        Decks.Release(gate);

        daemon.Shutdown(Timeout);

        Assert.True(GetRun(daemon, runningId)?.Succeeded);
        SimulationInfo? queued = GetRun(daemon, queuedId);
        Assert.NotNull(queued);
        Assert.Equal((SimulationStatus.Cancelled, "Not started"), (queued.Status, queued.StatusMessage));
        Assert.Equal("Not started: the daemon shut down", queued.Error);
    }

    /// <summary>Kill running runs at once with cancelRunning.</summary>
    [Fact]
    public void ShutdownCancelRunningKillsRunningRuns()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("gate.dck"), gated: true));
        WaitUntil(daemon, runId, Running);

        daemon.Shutdown(Timeout, cancelRunning: true);

        SimulationInfo? info = GetRun(daemon, runId);
        Assert.Equal((SimulationStatus.Cancelled, "Interrupted"), (info?.Status, info?.StatusMessage));
    }

    /// <summary>Close stdin once the timeout passes, saving running runs as interrupted.</summary>
    [Fact]
    public void ShutdownTimeoutInterruptsRunningRuns()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("gate.dck"), gated: true));
        WaitUntil(daemon, runId, Running);

        daemon.Shutdown(TimeSpan.FromMilliseconds(200));

        SimulationInfo? info = GetRun(daemon, runId);
        Assert.NotNull(info);
        Assert.True(info.IsFinished);
        Assert.Equal("Interrupted: the client disconnected", info.Error);
    }

    /// <summary>Keep the database readable, stop blocking in WaitForChanges(), and refuse new requests.</summary>
    [Fact]
    public void AfterShutdownReadsWorkAndRequestsFail()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("model.dck")));
        daemon.Shutdown(Timeout);

        var elapsed = Stopwatch.StartNew();
        daemon.WaitForChanges(daemon.StartPosition.Revision);
        Changes changes;
        using (SqliteConnection connection = daemon.OpenDatabase())
        {
            changes = connection.ReadChanges(daemon.StartPosition);
        }

        Assert.Equal("trnrund is closed", Assert.Throws<ClosedException>(() => daemon.WaitForChanges(changes.Next.Revision)).Message);

        Assert.True(elapsed.Elapsed < TimeSpan.FromSeconds(5));
        Assert.Equal([runId], changes.Runs.Select(info => info.RunId));
        Assert.Equal("trnrund is closed", Assert.Throws<ClosedException>(() => daemon.Add(_temp.File("model.dck"))).Message);
    }

    // -----------------------------------------------------------------
    // Following changes
    // -----------------------------------------------------------------

    /// <summary>Return false when nothing is saved within the timeout.</summary>
    [Fact]
    public void WaitForChangesTimesOutWithNoChanges()
    {
        Daemon daemon = Start();

        Assert.False(daemon.WaitForChanges(daemon.StartPosition.Revision, TimeSpan.FromMilliseconds(100)));
    }

    /// <summary>Wake a reader once a later revision is saved.</summary>
    [Fact]
    public void WaitForChangesAnnouncesSavedRevisions()
    {
        Daemon daemon = Start();
        daemon.Add(Decks.Write(_temp.File("model.dck")));

        Assert.True(daemon.WaitForChanges(0, Timeout));
    }

    /// <summary>Announce what a killed trnrund saved, then throw its exit instead of hanging.</summary>
    [Fact]
    public void CrashIsThrownAfterItsChanges()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("gate.dck"), gated: true));
        WaitUntil(daemon, runId, Running);

        ChangePosition position = daemon.StartPosition;
        long final;
        DaemonExitedException error;
        using (SqliteConnection connection = daemon.OpenDatabase()) // Opened before the crash, as a reader would be.
        {
            using (Process trnrund = Process.GetProcessById(daemon.ProcessId))
            {
                trnrund.Kill();
            }

            error = Assert.Throws<DaemonExitedException>(() =>
            {
                for (int attempt = 0; attempt < 100; attempt++)
                {
                    if (daemon.WaitForChanges(position.Revision, TimeSpan.FromMilliseconds(500)))
                    {
                        position = connection.ReadChanges(position).Next;
                    }
                }
            });
            final = TestDatabase.LatestRevision(connection);
        }

        Assert.StartsWith("trnrund exited with code", error.Message);
        Assert.NotNull(error.ExitCode);
        Assert.Equal(final, position.Revision); // Every saved change was read before the error.
    }
}

/// <summary>Tests that resolve relative paths from the working directory, which they change.</summary>
[Collection(nameof(WorkingDirectoryCollection))]
public sealed class WorkingDirectoryTests : IDisposable
{
    private readonly TempDirectory _temp = new();
    private readonly string _original = Environment.CurrentDirectory;

    /// <summary>Enters the temporary directory.</summary>
    public WorkingDirectoryTests()
    {
        Environment.CurrentDirectory = _temp.Path;
    }

    /// <summary>Restores the working directory, then deletes the temporary one.</summary>
    public void Dispose()
    {
        Environment.CurrentDirectory = _original;
        _temp.Dispose();
    }

    /// <summary>Resolve a relative deck here, not from the daemon's working directory.</summary>
    [Fact]
    public void RelativeDeckResolvesFromTheWorkingDirectory()
    {
        Decks.Write(_temp.File("model.dck"));
        using Daemon daemon = Daemon.Start(DaemonTests.Options(maxConcurrent: 1));

        long runId = daemon.Add("model.dck");

        Assert.Equal(_temp.File("model.dck"), DaemonTests.GetRun(daemon, runId)?.DeckFile);
    }

    /// <summary>Resolve a relative database path from the working directory.</summary>
    [Fact]
    public void OpenResolvesARelativePath()
    {
        using (SqliteConnection writer = TestDatabase.Create(_temp.File("runs.sqlite3")))
        {
            TestDatabase.InsertRun(writer);
        }

        using SqliteConnection connection = TrnrunDatabase.Open("runs.sqlite3");

        Assert.Equal(1L, TestDatabase.Execute(connection, "SELECT count(*) FROM runs"));
    }

    /// <summary>Resolve a relative TrnEXE path from the working directory, not the daemon's.</summary>
    [Fact]
    public void RelativeTrnexePathIsMadeAbsolute()
    {
        File.WriteAllText(_temp.File("TrnEXE64.exe"), "");

        Assert.Equal(
            [$"--trnexePath:{_temp.File("TrnEXE64.exe")}"],
            new SimulationSettings { TrnexePath = "TrnEXE64.exe" }.ToCliArgs());
    }
}
