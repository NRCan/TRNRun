using TRNRun.Internal;

namespace TRNRun.Tests;

/// <summary>Tests for the run records and the parsers of trnrund's rows.</summary>
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
    private SimulationInfo Parse(long runId) => RowParser.ParseRun(TestDatabase.FetchRow(_connection, "runs", "run_id", runId));

    // -----------------------------------------------------------------
    // Records
    // -----------------------------------------------------------------

    /// <summary>Report a run finished only once the daemon finished it.</summary>
    [Theory]
    [InlineData(SimulationState.Queued, false)]
    [InlineData(SimulationState.Running, false)]
    [InlineData(SimulationState.Finished, true)]
    public void SimulationInfoIsFinishedOnlyWhenFinished(SimulationState state, bool finished) =>
        Assert.Equal(finished, new SimulationInfo { RunId = 1, State = state }.IsFinished);

    /// <summary>Start with no events, no counts and no outcome.</summary>
    [Fact]
    public void SimulationInfoDefaultsDescribeAFreshRun()
    {
        var info = new SimulationInfo { RunId = 1, State = SimulationState.Queued };

        Assert.Null(info.Status);
        Assert.Null(info.Progress);
        Assert.Null(info.Config);
        Assert.Null(info.Setting);
        Assert.Equal((0, 0, 0), (info.Notices, info.Warnings, info.Fatals));
        Assert.False(info.Succeeded);
        Assert.Null(info.ExitCode);
        Assert.Equal("", info.Error);
        Assert.Empty(info.TrnrunArgs);
    }

    /// <summary>Let callers skip empty polls.</summary>
    [Fact]
    public void ChangesAreEmptyOnlyWhenNothingChanged()
    {
        Assert.True(Changes.None.IsEmpty);
        Assert.False(new Changes([new SimulationInfo { RunId = 1, State = SimulationState.Queued }], []).IsEmpty);
        Assert.False(new Changes([], [new LogEvent(1, 1, "Notice", 0.0)]).IsEmpty);
    }

    // -----------------------------------------------------------------
    // ParseRun
    // -----------------------------------------------------------------

    /// <summary>Turn a run TRNRun has not reported on into null events and an empty outcome.</summary>
    [Fact]
    public void ParseRunOfAQueuedRun()
    {
        long runId = TestDatabase.InsertRun(_connection, ("label", "baseline"), ("trnrun_args", """["--pollMs:10"]"""));

        SimulationInfo info = Parse(runId);

        Assert.Equal(runId, info.RunId);
        Assert.Equal(SimulationState.Queued, info.State);
        Assert.Equal(1, info.SessionId);
        Assert.Equal("baseline", info.Label);
        Assert.Equal(1, info.Revision);
        Assert.Equal(@"C:\decks\model.dck", info.DeckFile);
        Assert.Equal(["--pollMs:10"], info.TrnrunArgs);
        Assert.Null(info.Status);
        Assert.Null(info.Progress);
        Assert.Null(info.Config);
        Assert.Null(info.Setting);
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
        Assert.Equal(new StatusEvent(SimulationStatus.Done, "All good"), info.Status);
        Assert.Equal(new ProgressEvent(Time: 8_760.0, Percent: 1.0, ElapsedMs: 1_500.0, EtaMs: 0.0), info.Progress);
        Assert.Equal(new ConfigEvent(Start: 0.0, Stop: 8_760.0, Step: 1.0), info.Config);
        Assert.NotNull(info.Setting);
        Assert.Equal(TestDatabase.Setting["trnexePath"], info.Setting.TrnexePath);
        Assert.Equal(300_000, info.Setting.DetectTimeoutMs);
        Assert.Equal("hidden", info.Setting.GuiVisibility);
        Assert.Equal((3, 2, 1), (info.Notices, info.Warnings, info.Fatals));
        Assert.True(info.Succeeded);
        Assert.Equal(0, info.ExitCode);
        Assert.Equal("", info.Error);
        Assert.Equal(new DateTimeOffset(2026, 10, 9, 14, 3, 13, TimeSpan.Zero), info.StartedAt);
        Assert.Equal(new DateTimeOffset(2026, 10, 9, 14, 5, 0, 500, TimeSpan.Zero), info.FinishedAt);
        Assert.True(info.IsFinished);
    }

    /// <summary>Keep the daemon error and exit code, and read a NULL message as empty.</summary>
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

        Assert.Equal(new StatusEvent(SimulationStatus.Error, ""), info.Status);
        Assert.False(info.Succeeded);
        Assert.Equal(1, info.ExitCode);
        Assert.Equal("Cannot start TRNRun", info.Error);
    }

    /// <summary>Read a NULL succeeded as false until the run finishes.</summary>
    [Fact]
    public void ParseRunKeepsUnfinishedOutcomeFalse()
    {
        long runId = TestDatabase.InsertRun(_connection, ("state", "RUNNING"), ("started_at", "2026-10-09T14:03:13.000Z"));

        SimulationInfo info = Parse(runId);

        Assert.False(info.Succeeded);
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

        Assert.Equal(status, Parse(runId).Status?.Status);
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

    /// <summary>Fail on a SETTING key this package does not know instead of dropping it.</summary>
    [Fact]
    public void ParseRunRejectsAnUnknownSetting()
    {
        long runId = TestDatabase.InsertRun(_connection, ("setting", TestDatabase.SettingJson(with: ("newOption", 1))));

        var error = Assert.Throws<InvalidDataException>(() => Parse(runId));
        Assert.Contains("newOption", error.Message);
    }

    /// <summary>Fail on a SETTING that lacks one of the properties.</summary>
    [Fact]
    public void ParseRunRejectsAMissingSetting()
    {
        long runId = TestDatabase.InsertRun(_connection, ("setting", TestDatabase.SettingJson(without: "pollMs")));

        var error = Assert.Throws<InvalidDataException>(() => Parse(runId));
        Assert.Contains("pollMs", error.Message);
    }

    // -----------------------------------------------------------------
    // ParseLog
    // -----------------------------------------------------------------

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

        LogEvent log = RowParser.ParseLog(TestDatabase.FetchRow(_connection, "logs", "log_id", logId));

        Assert.Equal(new LogEvent(logId, 7, "Warning", 2_190.5, 12, 56, 123, "Example warning", "Example details"), log);
    }

    /// <summary>Keep the properties TRNSYS did not attach as null.</summary>
    [Fact]
    public void ParseLogWithOnlyRequiredFields()
    {
        long logId = TestDatabase.InsertLog(_connection, 3, ("severity", "Fatal"), ("sim_time", 1.0));

        Assert.Equal(
            new LogEvent(logId, 3, "Fatal", 1.0),
            RowParser.ParseLog(TestDatabase.FetchRow(_connection, "logs", "log_id", logId)));
    }
}
