namespace TRNRun.Tests;

/// <summary>Tests for <see cref="SimulationSettings"/> and <see cref="DaemonSettings"/>: the flags passed to TRNRun and trnrund.</summary>
public sealed class SettingsTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    /// <summary>Deletes the temporary directory.</summary>
    public void Dispose() => _temp.Dispose();

    // -----------------------------------------------------------------
    // SimulationSettings
    // -----------------------------------------------------------------

    /// <summary>Keep TRNRun's own defaults when no property is set.</summary>
    [Fact]
    public void DefaultSimulationSettingsPassNothing() =>
        Assert.Empty(new SimulationSettings().ToCliArgs());

    /// <summary>Keep the property names, flag names and values aligned with TRNRun's parser.</summary>
    [Fact]
    public void SimulationSettingsSerializeEveryRunnerOption()
    {
        string trnexe = _temp.File("TrnEXE64.exe");
        File.WriteAllText(trnexe, "");
        var settings = new SimulationSettings
        {
            TrnexePath = trnexe,
            GuiVisibility = GuiVisibility.MinimizedAuto,
            WaitForGui = false,
            WaitForLst = false,
            WaitForTmp = true,
            DetectTimeoutMs = 1_234,
            ExtraDelayMs = 25,
            PollMs = 50,
            WatchLog = false,
            WatchTmp = true,
            WatchTimeoutMs = 5_000,
            StallTimeoutMs = 3_000,
            CleanOnSuccess = true,
            KillOnTimeout = true,
            KillOnStall = true,
            Severity = LogSeverity.Warning,
            WriteEvents = true,
        };

        Assert.Equal(
            [
                $"--trnexePath:{trnexe}",
                "--guiVisibility:minimizedAuto",
                "--waitForGui:false",
                "--waitForLst:false",
                "--waitForTmp:true",
                "--detectTimeout:1234",
                "--extraDelay:25",
                "--pollMs:50",
                "--watchLog:false",
                "--watchTmp:true",
                "--watchTimeout:5000",
                "--stallTimeout:3000",
                "--clean:true",
                "--killOnTimeout:true",
                "--killOnStall:true",
                "--severity:Warning",
                "--writeEvents:true",
            ],
            settings.ToCliArgs());
    }

    /// <summary>Leave unset properties out, whatever their position.</summary>
    [Fact]
    public void SimulationSettingsPassOnlyThePropertiesSet() =>
        Assert.Equal(
            ["--pollMs:10", "--severity:Fatal"],
            new SimulationSettings { PollMs = 10, Severity = LogSeverity.Fatal }.ToCliArgs());

    /// <summary>Name every window behavior as TRNRun's parser does.</summary>
    [Theory]
    [InlineData(GuiVisibility.KeepOpen, "keepOpen")]
    [InlineData(GuiVisibility.AutoClose, "autoClose")]
    [InlineData(GuiVisibility.Minimized, "minimized")]
    [InlineData(GuiVisibility.MinimizedAuto, "minimizedAuto")]
    [InlineData(GuiVisibility.Hidden, "hidden")]
    public void GuiVisibilityUsesTrnrunKeywords(GuiVisibility visibility, string keyword) =>
        Assert.Equal([$"--guiVisibility:{keyword}"], new SimulationSettings { GuiVisibility = visibility }.ToCliArgs());

    /// <summary>Reject an undefined enum value instead of passing a number TRNRun would refuse later.</summary>
    [Fact]
    public void UndefinedEnumValuesAreRejected()
    {
        Assert.Throws<ArgumentOutOfRangeException>(() => new SimulationSettings { GuiVisibility = (GuiVisibility)99 }.ToCliArgs());
        Assert.Throws<ArgumentOutOfRangeException>(() => new SimulationSettings { Severity = (LogSeverity)99 }.ToCliArgs());
    }

    /// <summary>Keep every option TRNRun reports applying settable, under the same name.</summary>
    [Fact]
    public void SimulationSettingsMatchTheReportedSettingEvent()
    {
        string[] settable = typeof(SimulationSettings).GetProperties().Select(property => property.Name).Order().ToArray();
        string[] reported = typeof(SettingEvent).GetConstructors().Single().GetParameters().Select(parameter => parameter.Name!).Order().ToArray();

        Assert.Equal(reported, settable);
    }

    /// <summary>Report a missing TRNSYS installation when the arguments are built.</summary>
    [Fact]
    public void MissingTrnexeFailsBeforeQueuing()
    {
        var error = Assert.Throws<FileNotFoundException>(() => new SimulationSettings { TrnexePath = _temp.File("missing.exe") }.ToCliArgs());
        Assert.Contains("TrnEXE executable not found", error.Message);
    }

    /// <summary>Reject a directory given as the TrnEXE path.</summary>
    [Fact]
    public void TrnexePathMustBeAFile() =>
        Assert.Throws<FileNotFoundException>(() => new SimulationSettings { TrnexePath = _temp.Path }.ToCliArgs());

    /// <summary>Let <c>with</c> derive settings without changing the original.</summary>
    [Fact]
    public void SettingsAreImmutableRecords()
    {
        var original = new SimulationSettings { PollMs = 10 };
        SimulationSettings changed = original with { WatchTmp = true };

        Assert.Equal(["--pollMs:10"], original.ToCliArgs());
        Assert.Equal(["--pollMs:10", "--watchTmp:true"], changed.ToCliArgs());
    }

    // -----------------------------------------------------------------
    // DaemonSettings
    // -----------------------------------------------------------------

    /// <summary>Keep trnrund's own defaults when no property is set.</summary>
    [Fact]
    public void DefaultDaemonSettingsPassNothing() =>
        Assert.Empty(new DaemonSettings().ToCliArgs());

    /// <summary>Keep the trnrund flag names aligned with its parser.</summary>
    [Fact]
    public void DaemonSettingsSerializeEveryOption()
    {
        var settings = new DaemonSettings(_temp.File("trnrun.exe"), 4, _temp.File("runs.sqlite3"));

        Assert.Equal(
            [$"--trnrun:{_temp.File("trnrun.exe")}", "--maxConcurrent:4", $"--database:{_temp.File("runs.sqlite3")}"],
            settings.ToCliArgs());
    }
}

/// <summary>Tests for <see cref="SimulationStatus"/> and the typed events.</summary>
public sealed class EventsTests
{
    /// <summary>Keep the enum in TRNRun's STATUS order.</summary>
    [Fact]
    public void SimulationStatusValuesAreTheRunnerStatuses() =>
        Assert.Equal(
            ["Pending", "Launching", "Running", "Done", "Cancelled", "Error", "Timeout", "Stalled"],
            Enum.GetNames<SimulationStatus>());

    /// <summary>Report no detail as an empty message, not null.</summary>
    [Fact]
    public void StatusEventMessageDefaultsToEmpty() =>
        Assert.Equal("", new StatusEvent(SimulationStatus.Running).Message);

    /// <summary>Require only the severity and time TRNSYS always attaches.</summary>
    [Fact]
    public void LogEventOptionalPropertiesDefaultToNull()
    {
        var log = new LogEvent(LogId: 1, RunId: 2, Severity: "Notice", Time: 0.5);

        Assert.Null(log.UnitId);
        Assert.Null(log.TypeId);
        Assert.Null(log.MessageCode);
        Assert.Null(log.Message);
        Assert.Null(log.Information);
    }

    /// <summary>Let equal events deduplicate and compare equal.</summary>
    [Fact]
    public void EventsCompareAndHashByValue()
    {
        var first = new ProgressEvent(Time: 1.0, Percent: 0.5, ElapsedMs: 10.0, EtaMs: 10.0);
        var second = new ProgressEvent(Time: 1.0, Percent: 0.5, ElapsedMs: 10.0, EtaMs: 10.0);

        Assert.Equal(first, second);
        Assert.Single(new HashSet<ProgressEvent> { first, second });
    }
}
