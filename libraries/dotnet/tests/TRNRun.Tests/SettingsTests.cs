namespace TRNRun.Tests;

/// <summary>Tests for <see cref="SimulationSettings"/>: the flags passed to TRNRun.</summary>
public sealed class SettingsTests : IDisposable
{
    private readonly TempDirectory _temp = new();

    /// <summary>Deletes the temporary directory.</summary>
    public void Dispose() => _temp.Dispose();

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
            DetectTimeout = TimeSpan.FromMilliseconds(1_234),
            ExtraDelay = TimeSpan.FromMilliseconds(25),
            PollInterval = TimeSpan.FromMilliseconds(50),
            WatchLog = false,
            WatchTmp = true,
            WatchTimeout = TimeSpan.FromSeconds(5),
            StallTimeout = TimeSpan.FromSeconds(3),
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
            new SimulationSettings { PollInterval = TimeSpan.FromMilliseconds(10), Severity = LogSeverity.Fatal }.ToCliArgs());

    /// <summary>Pass an infinite timeout as TRNRun's unlimited, and round a partial millisecond up rather than to unlimited.</summary>
    [Fact]
    public void DurationsPassWholeMilliseconds() =>
        Assert.Equal(
            ["--detectTimeout:0", "--extraDelay:-1", "--pollMs:1", "--watchTimeout:0", "--stallTimeout:1"],
            new SimulationSettings
            {
                DetectTimeout = Timeout.InfiniteTimeSpan,
                ExtraDelay = Timeout.InfiniteTimeSpan, // Not a timeout, so left for trnrund to reject.
                PollInterval = TimeSpan.FromTicks(1),
                WatchTimeout = TimeSpan.Zero,
                StallTimeout = TimeSpan.FromMicroseconds(500),
            }.ToCliArgs());

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

    /// <summary>Keep every option TRNRun reports applying settable, under the same name less its <c>Ms</c> unit.</summary>
    [Fact]
    public void EveryReportedSettingIsSettable()
    {
        string[] settable = typeof(SimulationSettings).GetProperties().Select(property => property.Name).Order().ToArray();
        string[] reported = TestDatabase.Setting.Keys
            .Select(key => key == "pollMs" ? "pollInterval" : key.EndsWith("Ms", StringComparison.Ordinal) ? key[..^2] : key)
            .Select(key => char.ToUpperInvariant(key[0]) + key[1..])
            .Order()
            .ToArray();

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
        var original = new SimulationSettings { PollInterval = TimeSpan.FromMilliseconds(10) };
        SimulationSettings changed = original with { WatchTmp = true };

        Assert.Equal(["--pollMs:10"], original.ToCliArgs());
        Assert.Equal(["--pollMs:10", "--watchTmp:true"], changed.ToCliArgs());
    }
}
