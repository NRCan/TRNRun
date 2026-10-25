namespace TRNRun.Tests;

/// <summary>SimulationSettings turned into TRNRun flags.</summary>
public sealed class SimulationSettingsTests
{
    [Fact]
    public void UnsetPropertiesPassNoFlag() => Assert.Empty(new SimulationSettings().ToCliArgs());

    [Fact]
    public void EveryPropertyBecomesItsFlag()
    {
        string trnexe = Environment.ProcessPath!;
        var settings = new SimulationSettings
        {
            TrnexePath = trnexe,
            GuiVisibility = GuiVisibility.KeepOpen,
            WaitForGui = false,
            WaitForLst = true,
            WaitForTmp = true,
            DetectTimeout = Timeout.InfiniteTimeSpan,
            ExtraDelay = TimeSpan.FromSeconds(2),
            PollInterval = TimeSpan.FromTicks(1),
            WatchLog = true,
            WatchTmp = true,
            WatchTimeout = TimeSpan.FromMinutes(1),
            StallTimeout = TimeSpan.Zero,
            CleanOnSuccess = true,
            KillOnTimeout = true,
            KillOnStall = false,
            Severity = LogSeverity.Warning,
            WriteEvents = true,
        };
        Assert.Equal(
            [
                $"--trnexePath:{trnexe}", "--guiVisibility:keep", "--waitForGui:false", "--waitForLst:true",
                "--waitForTmp:true", "--detectTimeout:0", "--extraDelay:2000", "--pollMs:1", "--watchLog:true",
                "--watchTmp:true", "--watchTimeout:60000", "--stallTimeout:0", "--clean:true", "--killOnTimeout:true",
                "--killOnStall:false", "--severity:Warning", "--writeEvents:true",
            ],
            settings.ToCliArgs());
    }

    [Fact]
    public void AMissingTrnexeThrows() =>
        Assert.Throws<FileNotFoundException>(() => new SimulationSettings { TrnexePath = "missing.exe" }.ToCliArgs());
}
