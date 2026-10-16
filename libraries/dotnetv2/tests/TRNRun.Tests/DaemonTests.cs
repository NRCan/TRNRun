using System.Diagnostics;
using System.Text.Json;

namespace TRNRun.Tests;

/// <summary>Tests for <see cref="Daemon"/>: driving the bundled trnrund and following its runs.</summary>
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

    /// <summary>Starts a daemon on the fake TRNRun, by default with a temporary database and two slots.</summary>
    private Daemon Start(string? databasePath = null, int maxConcurrent = 2)
    {
        var daemon = new Daemon(databasePath, maxConcurrent: maxConcurrent, trnrunPath: Executables.FakeTrnrun);
        _started.Add(daemon);
        return daemon;
    }

    /// <summary>Follows the daemon's changes until run <paramref name="runId"/> satisfies <paramref name="done"/>, and returns it.</summary>
    internal static SimulationInfo WaitUntil(Daemon daemon, long runId, Func<SimulationInfo, bool> done)
    {
        var elapsed = Stopwatch.StartNew();
        while (elapsed.Elapsed < Timeout)
        {
            SimulationInfo? info = daemon.Database.GetRun(runId);
            if (info is not null && done(info))
            {
                return info;
            }

            daemon.Wait(TimeSpan.FromMilliseconds(500));
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

        var error = Assert.Throws<DaemonException>(() => Daemon.ReplyInt64(reply.RootElement, "runId"));
        Assert.Contains("trnrund reply has no integer 'runId'", error.Message);
    }

    // -----------------------------------------------------------------
    // Starting and closing
    // -----------------------------------------------------------------

    /// <summary>Report a missing trnrund executable by its path.</summary>
    [Fact]
    public void MissingTrnrundFailsToStart()
    {
        var error = Assert.Throws<FileNotFoundException>(
            () => new Daemon(_temp.File("runs.sqlite3"), trnrundPath: _temp.File("trnrund.exe")));
        Assert.Contains("trnrund executable not found", error.Message);
    }

    /// <summary>Keep the runs in a temporary database, deleted with the daemon.</summary>
    [Fact]
    public void TemporaryDatabaseIsDeletedOnDispose()
    {
        Daemon daemon = Start();

        Assert.True(File.Exists(daemon.DatabasePath));
        Assert.Equal((1L, 0L, 0L), (daemon.SessionId, daemon.StartRevision, daemon.StartLogId));
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
        Assert.Equal(path, second.DatabasePath);
        Assert.Equal(2, second.SessionId);
        Assert.True(second.StartRevision > 0);
        Assert.Equal(3, second.StartLogId);
        Assert.True(second.Poll().IsEmpty); // Only this daemon's changes.

        long secondRun = second.Add(deck);

        Assert.Equal(firstRun + 1, secondRun);
        Assert.Equal([firstRun], second.Database.GetRuns(sessionId: 1).Select(info => info.RunId));
        Assert.Equal([secondRun], second.Wait(Timeout).Runs.Select(info => info.RunId));
    }

    /// <summary>Throw trnrund's startup error, such as a database held by another daemon.</summary>
    [Fact]
    public void DatabaseInUseFailsWithTrnrundMessage()
    {
        string path = _temp.File("runs.sqlite3");
        Start(path);

        var error = Assert.Throws<DaemonException>(() => Start(path));
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

        using var database = new Database(path);
        SimulationInfo? info = database.GetRun(runId);

        Assert.NotNull(info);
        Assert.True(info.IsFinished);
        Assert.Equal(new StatusEvent(SimulationStatus.Cancelled, "Interrupted"), info.Status);
        Assert.Equal("Interrupted: the client disconnected", info.Error);
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
        Assert.Equal((0, ""), (info.ExitCode, info.Error));
        Assert.Equal("baseline", info.Label);
        Assert.Equal(daemon.SessionId, info.SessionId);
        Assert.Equal(["--pollMs:10"], info.TrnrunArgs);
        Assert.Equal(_temp.File("model.dck"), info.DeckFile);
        Assert.Equal(new StatusEvent(SimulationStatus.Done), info.Status);
        Assert.Equal(10.0, info.Config?.Stop);
        Assert.Equal(1.0, info.Progress?.Percent);
        Assert.Equal((1, 1, 1), (info.Notices, info.Warnings, info.Fatals));
        Assert.NotNull(info.SubmittedAt);
        Assert.NotNull(info.StartedAt);
        Assert.NotNull(info.FinishedAt);
        IReadOnlyList<LogEvent> logs = daemon.Database.GetLogs(runId);
        Assert.Equal(
            [("Notice", "first"), ("Warning", "second"), ("Fatal", "third")],
            logs.Select(log => (log.Severity, log.Message)));
        Assert.Equal((7L, 56L, 123L, "details"), (logs[1].UnitId, logs[1].TypeId, logs[1].MessageCode, logs[1].Information));
    }

    /// <summary>Hand out each saved change once, ending with the finished run and all its logs.</summary>
    [Fact]
    public void PollAndWaitReturnEveryChangeOnce()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("model.dck")));
        var runs = new List<SimulationInfo>();
        var logIds = new List<long>();
        var elapsed = Stopwatch.StartNew();
        while (!(runs.Count > 0 && runs[^1].IsFinished) && elapsed.Elapsed < Timeout)
        {
            Changes changes = daemon.Wait(TimeSpan.FromMilliseconds(500));
            runs.AddRange(changes.Runs);
            logIds.AddRange(changes.Logs.Select(log => log.LogId));
        }

        Assert.Equal(runId, runs[^1].RunId);
        Assert.True(runs[^1].IsFinished);
        Assert.Equal(runs.Select(info => info.Revision).Distinct().Order(), runs.Select(info => info.Revision));
        Assert.Equal([1, 2, 3], logIds);
        Assert.True(daemon.Poll().IsEmpty);
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
        Assert.Equal(new StatusEvent(SimulationStatus.Error, "Fake failure"), info.Status);
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
        Assert.Equal(new StatusEvent(SimulationStatus.Error, "TRNRun exited without a terminal status"), info.Status);
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

        Assert.Equal(settings.ToCliArgs(), daemon.Database.GetRun(runId)?.TrnrunArgs);
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

        var error = Assert.Throws<ArgumentException>(
            () => daemon.Add(_temp.File(deckName), arg.Length == 0 ? [] : [arg]));

        Assert.Contains(message, error.Message);
        Assert.Empty(daemon.Database.GetRuns());
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

        SimulationInfo? queued = daemon.Database.GetRun(queuedId);
        Assert.NotNull(queued);
        Assert.True(queued.IsFinished);
        Assert.Null(queued.StartedAt);
        Assert.Equal(new StatusEvent(SimulationStatus.Cancelled, "Not started"), queued.Status);
        Assert.Equal("Not started: cancelled by the client", queued.Error);

        daemon.Cancel(runningId);
        SimulationInfo cancelled = WaitUntil(daemon, runningId, Finished);

        Assert.Equal(new StatusEvent(SimulationStatus.Cancelled, "Interrupted"), cancelled.Status);
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

        SimulationInfo? after = daemon.Database.GetRun(runId);
        Assert.NotNull(after);
        Assert.Equal(before.Revision, after.Revision);
        Assert.True(after.Succeeded);
    }

    /// <summary>Reject a run ID trnrund never assigned.</summary>
    [Fact]
    public void CancelUnknownRunIsRejected()
    {
        Daemon daemon = Start();

        var error = Assert.Throws<ArgumentException>(() => daemon.Cancel(999));
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

        daemon.Shutdown(timeout: Timeout);

        Assert.True(daemon.Database.GetRun(runningId)?.Succeeded);
        SimulationInfo? queued = daemon.Database.GetRun(queuedId);
        Assert.NotNull(queued);
        Assert.Equal(new StatusEvent(SimulationStatus.Cancelled, "Not started"), queued.Status);
        Assert.Equal("Not started: the daemon shut down", queued.Error);
        Assert.Null(daemon.GetExitError());
    }

    /// <summary>Kill running runs at once with cancelRunning.</summary>
    [Fact]
    public void ShutdownCancelRunningKillsRunningRuns()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("gate.dck"), gated: true));
        WaitUntil(daemon, runId, Running);

        daemon.Shutdown(cancelRunning: true, timeout: Timeout);

        Assert.Equal(new StatusEvent(SimulationStatus.Cancelled, "Interrupted"), daemon.Database.GetRun(runId)?.Status);
    }

    /// <summary>Close stdin once the timeout passes, saving running runs as interrupted.</summary>
    [Fact]
    public void ShutdownTimeoutInterruptsRunningRuns()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("gate.dck"), gated: true));
        WaitUntil(daemon, runId, Running);

        daemon.Shutdown(timeout: TimeSpan.FromMilliseconds(200));

        SimulationInfo? info = daemon.Database.GetRun(runId);
        Assert.NotNull(info);
        Assert.True(info.IsFinished);
        Assert.Equal("Interrupted: the client disconnected", info.Error);
    }

    /// <summary>Keep the database readable, stop blocking in Wait(), and refuse new requests.</summary>
    [Fact]
    public void AfterShutdownReadsWorkAndRequestsFail()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("model.dck")));
        daemon.Shutdown(timeout: Timeout);

        var elapsed = Stopwatch.StartNew();
        Changes changes = daemon.Wait();

        Assert.True(elapsed.Elapsed < TimeSpan.FromSeconds(5));
        Assert.Equal([runId], changes.Runs.Select(info => info.RunId));
        Assert.Null(daemon.GetExitError());
        var error = Assert.Throws<DaemonException>(() => daemon.Add(_temp.File("model.dck")));
        Assert.Equal("trnrund is closed", error.Message);
    }

    // -----------------------------------------------------------------
    // Following changes
    // -----------------------------------------------------------------

    /// <summary>Return empty Changes when nothing is saved within the timeout.</summary>
    [Fact]
    public void WaitTimesOutWithNoChanges()
    {
        Daemon daemon = Start();

        Assert.True(daemon.Wait(TimeSpan.FromMilliseconds(100)).IsEmpty);
        Assert.False(daemon.WaitForChange(daemon.Database.Revision, TimeSpan.FromMilliseconds(100)));
    }

    /// <summary>Wake readers with their own database once a later revision is saved.</summary>
    [Fact]
    public void WaitForChangeAnnouncesSavedRevisions()
    {
        Daemon daemon = Start();
        daemon.Add(Decks.Write(_temp.File("model.dck")));

        Assert.True(daemon.WaitForChange(0, Timeout));
    }

    /// <summary>Return what a crashed trnrund saved, then throw its exit instead of hanging.</summary>
    [Fact]
    public void CrashIsThrownAfterItsChanges()
    {
        Daemon daemon = Start();
        long runId = daemon.Add(Decks.Write(_temp.File("gate.dck"), gated: true));
        WaitUntil(daemon, runId, Running);
        using (Process trnrund = Process.GetProcessById(daemon.ProcessId))
        {
            trnrund.Kill();
        }

        var error = Assert.Throws<DaemonException>(() =>
        {
            for (int attempt = 0; attempt < 100; attempt++)
            {
                daemon.Wait(TimeSpan.FromMilliseconds(500));
            }
        });

        Assert.StartsWith("trnrund exited with code", error.Message);
        Assert.NotNull(daemon.GetExitError());
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
        using var daemon = new Daemon(maxConcurrent: 1, trnrunPath: Executables.FakeTrnrun);

        long runId = daemon.Add("model.dck");

        Assert.Equal(_temp.File("model.dck"), daemon.Database.GetRun(runId)?.DeckFile);
    }

    /// <summary>Resolve a relative database path from the working directory.</summary>
    [Fact]
    public void DatabaseRecordsAnAbsolutePath()
    {
        TestDatabase.Create(_temp.File("runs.sqlite3")).Dispose();

        using var database = new Database("runs.sqlite3");

        Assert.Equal(_temp.File("runs.sqlite3"), database.Path);
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

    /// <summary>Resolve daemon paths here, and leave checking that they exist to trnrund.</summary>
    [Fact]
    public void DaemonSettingsMakePathsAbsoluteWithoutCheckingThem() =>
        Assert.Equal(
            [$"--trnrun:{Path.Combine(_temp.Path, "bin", "trnrun.exe")}", $"--database:{_temp.File("runs.sqlite3")}"],
            new DaemonSettings(TrnrunPath: @"bin\trnrun.exe", DatabasePath: "runs.sqlite3").ToCliArgs());
}
