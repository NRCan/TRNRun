namespace TRNRun.Tests;

/// <summary>Tests for <see cref="SimulationSettings"/>: the flags passed to TRNRun.</summary>
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
    public void EveryReportedSettingIsSettable()
    {
        string[] settable = typeof(SimulationSettings).GetProperties().Select(property => property.Name).Order().ToArray();
        string[] reported = TestDatabase.Setting.Keys.Select(key => char.ToUpperInvariant(key[0]) + key[1..]).Order().ToArray();

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
}
