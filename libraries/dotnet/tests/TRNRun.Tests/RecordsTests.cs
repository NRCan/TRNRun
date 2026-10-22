namespace TRNRun.Tests;

/// <summary>Tests for the record, enum and exception types.</summary>
public sealed class RecordsTests
{
    /// <summary>Returns a queued run with every required property set.</summary>
    private static SimulationInfo Info(SimulationState state = SimulationState.Queued) => new()
    {
        RunId = 1,
        State = state,
        DeckFile = "model.dck",
        SessionId = 1,
        Revision = 1,
        TrnrunArgs = [],
        Notices = 0,
        Warnings = 0,
        Fatals = 0,
        SubmittedAt = DateTimeOffset.UnixEpoch,
    };

    /// <summary>Keep the enum in TRNRun's STATUS order.</summary>
    [Fact]
    public void SimulationStatusValuesAreTheRunnerStatuses() =>
        Assert.Equal(
            ["Pending", "Launching", "Running", "Done", "Cancelled", "Error", "Timeout", "Stalled"],
            Enum.GetNames<SimulationStatus>());

    /// <summary>Name each state as trnrund saves it, for queries on the state column.</summary>
    [Fact]
    public void StateNamesAreTheDaemonNames() =>
        Assert.Equal(["QUEUED", "RUNNING", "FINISHED"], Enum.GetValues<SimulationState>().Select(state => state.ToDatabaseName()));

    /// <summary>Name each status as TRNRun saves it, for queries on the trnrun_status column.</summary>
    [Fact]
    public void StatusNamesAreTheRunnerNames() =>
        Assert.Equal(
            ["PENDING", "LAUNCHING", "RUNNING", "DONE", "CANCELLED", "ERROR", "TIMEOUT", "STALLED"],
            Enum.GetValues<SimulationStatus>().Select(status => status.ToDatabaseName()));

    /// <summary>Name each severity as TRNSYS saves it, for queries on the severity column.</summary>
    [Fact]
    public void SeverityNamesAreTheTrnsysNames() =>
        Assert.Equal(["Notice", "Warning", "Fatal"], Enum.GetValues<LogSeverity>().Select(severity => severity.ToDatabaseName()));

    /// <summary>Reject an undefined value rather than name it.</summary>
    [Fact]
    public void UndefinedValuesHaveNoDatabaseName()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => ((SimulationStatus)99).ToDatabaseName());
        Assert.Throws<ArgumentOutOfRangeException>(() => ((LogSeverity)99).ToDatabaseName());
    }

    /// <summary>Report a run finished only once the daemon finished it.</summary>
    [Theory]
    [InlineData(SimulationState.Queued, false)]
    [InlineData(SimulationState.Running, false)]
    [InlineData(SimulationState.Finished, true)]
    public void SimulationInfoIsFinishedOnlyWhenFinished(SimulationState state, bool finished) =>
        Assert.Equal(finished, Info(state).IsFinished);

    /// <summary>Start with no events and no outcome.</summary>
    [Fact]
    public void SimulationInfoOptionalPropertiesDefaultToNull()
    {
        SimulationInfo info = Info();

        Assert.Equal((null, null, null, null, null, null), (info.Label, info.Status, info.StatusMessage, info.Progress, info.Config, info.Setting));
        Assert.Equal((null, null, null), (info.Succeeded, info.ExitCode, info.Error));
        Assert.Equal((null, null), (info.StartedAt, info.FinishedAt));
    }

    /// <summary>Let callers skip empty reads.</summary>
    [Fact]
    public void ChangesAreEmptyOnlyWhenNothingChanged()
    {
        Assert.True(new Changes([], [], default).IsEmpty);
        Assert.False(new Changes([Info()], [], new(1, 0)).IsEmpty);
        Assert.False(new Changes([], [new LogEvent(1, 1, LogSeverity.Notice, 0.0)], new(0, 1)).IsEmpty);
    }

    /// <summary>Give the other exceptions the standard constructors, and describe an exit from its code and diagnostics.</summary>
    [Fact]
    public void ExceptionsHaveTheStandardConstructors()
    {
        var inner = new InvalidOperationException("inner");

        Assert.Same(inner, new RequestRejectedException("outer", inner).InnerException);
        Assert.Same(inner, new DaemonClosedException("outer", inner).InnerException);
        Assert.Same(inner, new SchemaVersionException("outer", inner).InnerException);
        Assert.IsAssignableFrom<TrnrunException>(new DaemonExitedException(1, ""));
        Assert.Equal("trnrund exited with code 2: bye", new DaemonExitedException(2, "bye").Message);
        Assert.Equal("trnrund closed its output but did not exit", new DaemonExitedException(null, "").Message);
    }

    /// <summary>Require only the severity and time TRNSYS always attaches.</summary>
    [Fact]
    public void LogEventOptionalPropertiesDefaultToNull()
    {
        var log = new LogEvent(LogId: 1, RunId: 2, Severity: LogSeverity.Notice, Time: 0.5);

        Assert.Equal((null, null, null, null, null), (log.UnitId, log.TypeId, log.MessageCode, log.Message, log.Information));
    }

    /// <summary>Let equal events deduplicate and compare equal.</summary>
    [Fact]
    public void EventsCompareAndHashByValue()
    {
        var first = new ProgressEvent(Time: 1.0, Percent: 0.5, Elapsed: TimeSpan.FromSeconds(10), Eta: TimeSpan.FromSeconds(10));
        var second = new ProgressEvent(Time: 1.0, Percent: 0.5, Elapsed: TimeSpan.FromSeconds(10), Eta: TimeSpan.FromSeconds(10));

        Assert.Equal(first, second);
        Assert.Single(new HashSet<ProgressEvent> { first, second });
    }
}
