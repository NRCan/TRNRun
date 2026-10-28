using System.Text.Json.Nodes;

namespace TRNRun;

/// <summary>TRNRun options for a simulation; each property's doc names the trnrun.exe flag it becomes.</summary>
/// <remarks>
/// <para>A <see langword="null"/> property passes no flag, so TRNRun's default applies; <c>trnrun.exe --help</c> lists them.</para>
/// <para>
/// Durations are passed as whole milliseconds, rounded up. For the timeouts, <see cref="Timeout.InfiniteTimeSpan"/>
/// and <see cref="TimeSpan.Zero"/> both mean no limit. Relative paths resolve from the current directory.
/// </para>
/// <para>TRNRun checks the values when the simulation starts, so a bad value finishes it with <see cref="SimulationStatus.Error"/> and a message saying why.</para>
/// </remarks>
public sealed record SimulationSettings
{
    /// <summary>TRNSYS executable, TrnEXE64.exe or TrnEXE.exe; must exist (<c>--trnexePath</c>).</summary>
    public string? TrnexePath { get; init; }

    /// <summary>Whether the TRNSYS window shows, and whether it closes after the run (<c>--guiVisibility</c>).</summary>
    public GuiVisibility? GuiVisibility { get; init; }

    /// <summary>Whether launch detection waits for the TRNSYS window to appear (<c>--waitForGui</c>).</summary>
    public bool? WaitForGui { get; init; }

    /// <summary>Whether launch detection waits for the component-order header in the <c>.lst</c> file (<c>--waitForLst</c>).</summary>
    public bool? WaitForLst { get; init; }

    /// <summary>Whether launch detection waits for the <c>.tmp</c> file; requires Type3830 in the deck (<c>--waitForTmp</c>).</summary>
    public bool? WaitForTmp { get; init; }

    /// <summary>How long launch detection may take, not counting <see cref="ExtraDelay"/> (<c>--detectTimeout</c>).</summary>
    public TimeSpan? DetectTimeout { get; init; }

    /// <summary>Extra wait after launch detection succeeds (<c>--extraDelay</c>).</summary>
    public TimeSpan? ExtraDelay { get; init; }

    /// <summary>How often TRNRun checks the output files and the TRNSYS process; at least 1 ms (<c>--pollMs</c>).</summary>
    public TimeSpan? PollInterval { get; init; }

    /// <summary>Whether to read <c>.log</c> entries into <see cref="Simulation.Logs"/> while TRNSYS runs (<c>--watchLog</c>).</summary>
    public bool? WatchLog { get; init; }

    /// <summary>Whether to report progress and the deck's times from the <c>.tmp</c> file, and detect stalls; requires Type3830 in the deck (<c>--watchTmp</c>).</summary>
    public bool? WatchTmp { get; init; }

    /// <summary>How long the run may take once launched before it ends as <see cref="SimulationStatus.Timeout"/> (<c>--watchTimeout</c>).</summary>
    public TimeSpan? WatchTimeout { get; init; }

    /// <summary>How long the run may go without progress before it ends as <see cref="SimulationStatus.Stalled"/>; requires <see cref="WatchTmp"/> (<c>--stallTimeout</c>).</summary>
    public TimeSpan? StallTimeout { get; init; }

    /// <summary>Whether to delete the <c>.tmp</c>, <c>.log</c>, <c>.lst</c> and <c>.PTI</c> files after a successful run (<c>--clean</c>).</summary>
    public bool? CleanOnSuccess { get; init; }

    /// <summary>Whether to kill TRNSYS when a detection or watch timeout expires, rather than leave it running (<c>--killOnTimeout</c>).</summary>
    public bool? KillOnTimeout { get; init; }

    /// <summary>Whether to kill TRNSYS when it stalls, rather than leave it running (<c>--killOnStall</c>).</summary>
    public bool? KillOnStall { get; init; }

    /// <summary>Least severe log entry reported; <see cref="LogSeverity.Warning"/> drops notices (<c>--severity</c>).</summary>
    public LogSeverity? Severity { get; init; }

    /// <summary>Whether TRNRun also writes its events to a <c>.jsonl</c> file beside the deck (<c>--writeEvents</c>).</summary>
    public bool? WriteEvents { get; init; }

    /// <summary>Returns trnrund's <c>trnrunOptions</c> for the properties that are set, keyed by TRNRun option, with <see cref="TrnexePath"/> made absolute.</summary>
    /// <exception cref="FileNotFoundException">A set <see cref="TrnexePath"/> is not an existing file.</exception>
    /// <exception cref="ArgumentOutOfRangeException"><see cref="GuiVisibility"/> is not a defined value; other bad values are left for TRNRun to refuse.</exception>
    internal JsonObject ToTrnrunOptions()
    {
        var options = new JsonObject();
        Add(options, "trnexePath", TrnexePath is null ? null : ResolveTrnexe(TrnexePath));
        Add(options, "guiVisibility", GuiVisibility is { } visibility ? GuiVisibilityName(visibility) : null);
        Add(options, "waitForGui", WaitForGui);
        Add(options, "waitForLst", WaitForLst);
        Add(options, "waitForTmp", WaitForTmp);
        Add(options, "detectTimeout", Unlimited(DetectTimeout));
        Add(options, "extraDelay", ExtraDelay);
        Add(options, "pollMs", PollInterval);
        Add(options, "watchLog", WatchLog);
        Add(options, "watchTmp", WatchTmp);
        Add(options, "watchTimeout", Unlimited(WatchTimeout));
        Add(options, "stallTimeout", Unlimited(StallTimeout));
        Add(options, "clean", CleanOnSuccess);
        Add(options, "killOnTimeout", KillOnTimeout);
        Add(options, "killOnStall", KillOnStall);
        Add(options, "severity", Severity?.ToString());
        Add(options, "writeEvents", WriteEvents);
        return options;
    }

    /// <summary>Sets the option unless the value is <see langword="null"/>.</summary>
    private static void Add(JsonObject options, string option, JsonNode? value)
    {
        if (value is not null)
        {
            options[option] = value;
        }
    }

    /// <summary>Sets a duration option in whole milliseconds, rounded up so a short timeout never becomes unlimited, unless unset.</summary>
    private static void Add(JsonObject options, string option, TimeSpan? value) =>
        Add(options, option, value is { } duration ? (long)Math.Ceiling(duration.TotalMilliseconds) : null);

    /// <summary>Maps <see cref="Timeout.InfiniteTimeSpan"/> to zero, which TRNRun reads as no limit.</summary>
    private static TimeSpan? Unlimited(TimeSpan? timeout) => timeout == Timeout.InfiniteTimeSpan ? TimeSpan.Zero : timeout;

    /// <summary>Returns the absolute TrnEXE path, checking that the file exists.</summary>
    private static string ResolveTrnexe(string path)
    {
        string trnexe = Path.GetFullPath(path);
        if (!File.Exists(trnexe))
        {
            throw new FileNotFoundException($"TrnEXE executable not found: {trnexe}", trnexe);
        }

        return trnexe;
    }

    /// <summary>Returns the <c>--guiVisibility</c> keyword for a window behavior.</summary>
    private static string GuiVisibilityName(GuiVisibility value) => value switch
    {
        TRNRun.GuiVisibility.KeepOpen => "keep",
        TRNRun.GuiVisibility.AutoClose => "auto",
        TRNRun.GuiVisibility.Minimized => "min",
        TRNRun.GuiVisibility.MinimizedAuto => "minauto",
        TRNRun.GuiVisibility.Hidden => "hidden",
        _ => throw new ArgumentOutOfRangeException(nameof(GuiVisibility), value, "Unknown GUI visibility."),
    };
}
