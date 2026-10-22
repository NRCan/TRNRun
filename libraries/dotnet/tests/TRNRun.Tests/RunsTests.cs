using Microsoft.Data.Sqlite;

namespace TRNRun.Tests;

/// <summary>Tests for <see cref="TrnrunDatabase.GetSimulationInfo"/> and <see cref="TrnrunDatabase.GetLogEvent"/>.</summary>
public sealed class RunsTests : IDisposable
{
    private readonly TempDirectory _temp = new();
    private readonly SqliteConnection _connection;

    /// <summary>Creates an empty trnrund database with a writable connection to it.</summary>
    public RunsTests()
    {
        _connection = TestDatabase.Create(_temp.File("runs.sqlite3"));
    }

    /// <summary>Closes the connection and deletes the database.</summary>
    public void Dispose()
    {
        _connection.Dispose();
        _temp.Dispose();
    }

    /// <summary>Returns a run's row parsed.</summary>
    private SimulationInfo Parse(long runId) => TestDatabase.FetchRun(_connection, runId)!;

    /// <summary>Turn a run TRNRun has not reported on into null events and an empty outcome.</summary>
    [Fact]
    public void ParseRunOfAQueuedRun()
    {
        long runId = TestDatabase.InsertRun(_connection, ("label", "baseline"), ("trnrun_args", """["--pollMs:10"]"""));

        SimulationInfo info = Parse(runId);

        Assert.Equal((runId, SimulationState.Queued, 1L, "baseline", 1L), (info.RunId, info.State, info.SessionId, info.Label, info.Revision));
        Assert.Equal(@"C:\decks\model.dck", info.DeckFile);
        Assert.Equal(["--pollMs:10"], info.TrnrunArgs);
        Assert.Equal((null, null, null, null, null), (info.Status, info.StatusMessage, info.Progress, info.Config, info.Setting));
        Assert.Equal((null, null, null), (info.Succeeded, info.ExitCode, info.Error));
        Assert.Equal(new DateTimeOffset(2026, 10, 9, 14, 3, 12, 345, TimeSpan.Zero), info.SubmittedAt);
        Assert.Null(info.StartedAt);
        Assert.Null(info.FinishedAt);
    }

    /// <summary>Group the flattened columns back into the events they came from.</summary>
    [Fact]
    public void ParseRunOfAFinishedRun()
    {
        long runId = TestDatabase.InsertRun(
            _connection,
            ("session_id", 4),
            ("state", "FINISHED"),
            ("trnrun_status", "DONE"),
            ("trnrun_message", "All good"),
            ("percent", 1.0),
            ("sim_time", 8_760.0),
            ("elapsed_ms", 1_500.0),
            ("eta_ms", 0.0),
            ("start_time", 0.0),
            ("stop_time", 8_760.0),
            ("time_step", 1.0),
            ("setting", TestDatabase.SettingJson()),
            ("notices", 3),
            ("warnings", 2),
            ("fatals", 1),
            ("succeeded", 1),
            ("exit_code", 0),
            ("started_at", "2026-10-09T14:03:13.000Z"),
            ("finished_at", "2026-10-09T14:05:00.500Z"));

        SimulationInfo info = Parse(runId);

        Assert.Equal(SimulationState.Finished, info.State);
        Assert.Equal(4, info.SessionId);
        Assert.Equal((SimulationStatus.Done, "All good"), (info.Status, info.StatusMessage));
        Assert.Equal(new ProgressEvent(Time: 8_760.0, Percent: 1.0, Elapsed: TimeSpan.FromMilliseconds(1_500), Eta: TimeSpan.Zero), info.Progress);
        Assert.Equal(new ConfigEvent(Start: 0.0, Stop: 8_760.0, Step: 1.0), info.Config);
        Assert.NotNull(info.Setting);
        Assert.Equal(TestDatabase.Setting.Keys.Order(), info.Setting.Keys.Order());
        Assert.Equal(TestDatabase.Setting["trnexePath"], info.Setting["trnexePath"].GetString());
        Assert.Equal(300_000, info.Setting["detectTimeoutMs"].GetInt64());
        Assert.True(info.Setting["waitForGui"].GetBoolean());
        Assert.Equal((3, 2, 1), (info.Notices, info.Warnings, info.Fatals));
        Assert.Equal((true, 0, null), (info.Succeeded, info.ExitCode, info.Error));
        Assert.Equal(new DateTimeOffset(2026, 10, 9, 14, 3, 13, TimeSpan.Zero), info.StartedAt);
        Assert.Equal(new DateTimeOffset(2026, 10, 9, 14, 5, 0, 500, TimeSpan.Zero), info.FinishedAt);
        Assert.True(info.IsFinished);
    }

    /// <summary>Keep the daemon error and exit code, and read a NULL message as null.</summary>
    [Fact]
    public void ParseRunOfAFailedRun()
    {
        long runId = TestDatabase.InsertRun(
            _connection,
            ("state", "FINISHED"),
            ("trnrun_status", "ERROR"),
            ("succeeded", 0),
            ("exit_code", 1),
            ("error", "Cannot start TRNRun"));

        SimulationInfo info = Parse(runId);

        Assert.Equal((SimulationStatus.Error, null), (info.Status, info.StatusMessage));
        Assert.Equal((false, 1, "Cannot start TRNRun"), (info.Succeeded, info.ExitCode, info.Error));
    }

    /// <summary>Read a NULL succeeded as null until the run finishes, so unfinished is not failed.</summary>
    [Fact]
    public void ParseRunKeepsUnfinishedOutcomeNull()
    {
        long runId = TestDatabase.InsertRun(_connection, ("state", "RUNNING"), ("started_at", "2026-10-09T14:03:13.000Z"));

        SimulationInfo info = Parse(runId);

        Assert.Null(info.Succeeded);
        Assert.Null(info.ExitCode);
        Assert.NotNull(info.StartedAt);
        Assert.Null(info.FinishedAt);
    }

    /// <summary>Read every status TRNRun writes.</summary>
    [Theory]
    [InlineData("PENDING", SimulationStatus.Pending)]
    [InlineData("LAUNCHING", SimulationStatus.Launching)]
    [InlineData("RUNNING", SimulationStatus.Running)]
    [InlineData("DONE", SimulationStatus.Done)]
    [InlineData("CANCELLED", SimulationStatus.Cancelled)]
    [InlineData("ERROR", SimulationStatus.Error)]
    [InlineData("TIMEOUT", SimulationStatus.Timeout)]
    [InlineData("STALLED", SimulationStatus.Stalled)]
    public void ParseRunReadsEveryStatus(string saved, SimulationStatus status)
    {
        long runId = TestDatabase.InsertRun(_connection, ("trnrun_status", saved));

        Assert.Equal(status, Parse(runId).Status);
    }

    /// <summary>Fail on a state saved by a newer trnrund rather than misreport it.</summary>
    [Fact]
    public void ParseRunRejectsAnUnknownState()
    {
        long runId = TestDatabase.InsertRun(_connection, ("state", "PAUSED"));

        var error = Assert.Throws<InvalidDataException>(() => Parse(runId));
        Assert.Contains("PAUSED", error.Message);
    }

    /// <summary>Fail on a status this package does not know, including other casings.</summary>
    [Theory]
    [InlineData("BOGUS")]
    [InlineData("done")]
    public void ParseRunRejectsAnUnknownStatus(string saved)
    {
        long runId = TestDatabase.InsertRun(_connection, ("trnrun_status", saved));

        var error = Assert.Throws<InvalidDataException>(() => Parse(runId));
        Assert.Contains(saved, error.Message);
    }

    /// <summary>Report unreadable saved JSON as invalid data.</summary>
    [Fact]
    public void ParseRunRejectsUnreadableJson()
    {
        long runId = TestDatabase.InsertRun(_connection, ("setting", "{not json"));

        Assert.Throws<InvalidDataException>(() => Parse(runId));
    }

    /// <summary>Report a duration that is not a number of milliseconds as invalid data, not an overflow.</summary>
    [Fact]
    public void ParseRunRejectsAnInfiniteDuration()
    {
        long runId = TestDatabase.InsertRun(
            _connection, ("percent", 0.5), ("sim_time", 1.0), ("elapsed_ms", 1.0), ("eta_ms", double.PositiveInfinity));

        var error = Assert.Throws<InvalidDataException>(() => Parse(runId));
        Assert.Contains("eta_ms", error.Message);
    }

    /// <summary>Read each column into its LogEvent property.</summary>
    [Fact]
    public void ParseLogWithEveryField()
    {
        long logId = TestDatabase.InsertLog(
            _connection,
            7,
            ("severity", "Warning"),
            ("sim_time", 2_190.5),
            ("unit_id", 12),
            ("type_id", 56),
            ("message_code", 123),
            ("message", "Example warning"),
            ("information", "Example details"));

        Assert.Equal(
            new LogEvent(logId, 7, LogSeverity.Warning, 2_190.5, 12, 56, 123, "Example warning", "Example details"),
            TestDatabase.FetchLog(_connection, logId));
    }

    /// <summary>Keep the properties TRNSYS did not attach as null.</summary>
    [Fact]
    public void ParseLogWithOnlyRequiredFields()
    {
        long logId = TestDatabase.InsertLog(_connection, 3, ("severity", "Fatal"), ("sim_time", 1.0));

        Assert.Equal(new LogEvent(logId, 3, LogSeverity.Fatal, 1.0), TestDatabase.FetchLog(_connection, logId));
    }

    /// <summary>Fail on a severity this package does not know.</summary>
    [Fact]
    public void ParseLogRejectsAnUnknownSeverity()
    {
        long logId = TestDatabase.InsertLog(_connection, 3, ("severity", "Debug"));

        var error = Assert.Throws<InvalidDataException>(() => TestDatabase.FetchLog(_connection, logId));
        Assert.Contains("Debug", error.Message);
    }
}
