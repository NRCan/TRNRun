using System.Text.Json.Nodes;

namespace TRNRun.Tests;

/// <summary>SimulationSettings turned into trnrund's trnrunOptions.</summary>
public sealed class SimulationSettingsTests
{
    [Fact]
    public void UnsetPropertiesPassNoOption() => Assert.Empty(new SimulationSettings().ToTrnrunOptions());

    [Fact]
    public void EveryPropertyBecomesItsOption()
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
            new JsonObject
            {
                ["trnexePath"] = trnexe, ["guiVisibility"] = "keep", ["waitForGui"] = false, ["waitForLst"] = true,
                ["waitForTmp"] = true, ["detectTimeout"] = 0, ["extraDelay"] = 2000, ["pollMs"] = 1, ["watchLog"] = true,
                ["watchTmp"] = true, ["watchTimeout"] = 60000, ["stallTimeout"] = 0, ["clean"] = true, ["killOnTimeout"] = true,
                ["killOnStall"] = false, ["severity"] = "Warning", ["writeEvents"] = true,
            }.ToJsonString(),
            settings.ToTrnrunOptions().ToJsonString());
    }

    [Theory]
    [InlineData(GuiVisibility.KeepOpen, "keep")]
    [InlineData(GuiVisibility.AutoClose, "auto")]
    [InlineData(GuiVisibility.Minimized, "min")]
    [InlineData(GuiVisibility.MinimizedAuto, "minauto")]
    [InlineData(GuiVisibility.Hidden, "hidden")]
    public void EveryGuiVisibilityBecomesTrnrunsKeyword(GuiVisibility visibility, string keyword) =>
        Assert.Equal(keyword, new SimulationSettings { GuiVisibility = visibility }.ToTrnrunOptions()["guiVisibility"]!.GetValue<string>());

    [Fact]
    public void AnUndefinedGuiVisibilityThrows() =>
        Assert.Throws<ArgumentOutOfRangeException>(() => new SimulationSettings { GuiVisibility = (GuiVisibility)99 }.ToTrnrunOptions());

    [Fact]
    public void AMissingTrnexeThrows() =>
        Assert.Throws<FileNotFoundException>(() => new SimulationSettings { TrnexePath = "missing.exe" }.ToTrnrunOptions());
}
