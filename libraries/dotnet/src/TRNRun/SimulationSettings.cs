using System.Globalization;

namespace TRNRun;

/// <summary>TRNRun options for a simulation; each property's doc names the trnrun.exe flag it becomes.</summary>
/// <remarks>
/// <para>A <see langword="null"/> property passes no flag, so TRNRun's default applies; <c>trnrun.exe --help</c> lists them.</para>
/// <para>
/// Durations are passed as whole milliseconds, rounded up. For the timeouts, <see cref="Timeout.InfiniteTimeSpan"/>
/// and <see cref="TimeSpan.Zero"/> both mean no limit. Relative paths resolve from the current directory.
/// </para>
/// <para>trnrund validates the values when the simulation is added, so a bad value throws from <see cref="TRNRunDaemon.AddAsync"/>.</para>
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

    /// <summary>Returns the TRNRun flags for the properties that are set, one unquoted argument each, with <see cref="TrnexePath"/> made absolute.</summary>
    /// <exception cref="FileNotFoundException">A set <see cref="TrnexePath"/> is not an existing file.</exception>
    /// <exception cref="ArgumentOutOfRangeException"><see cref="GuiVisibility"/> is not a defined value; other bad values are left for trnrund to refuse.</exception>
    internal IReadOnlyList<string> ToCliArgs()
    {
        var args = new List<string>();
        Add(args, "trnexePath", TrnexePath is null ? null : ResolveTrnexe(TrnexePath));
        Add(args, "guiVisibility", GuiVisibility is { } visibility ? GuiVisibilityName(visibility) : null);
        Add(args, "waitForGui", WaitForGui);
        Add(args, "waitForLst", WaitForLst);
        Add(args, "waitForTmp", WaitForTmp);
        Add(args, "detectTimeout", Unlimited(DetectTimeout));
        Add(args, "extraDelay", ExtraDelay);
        Add(args, "pollMs", PollInterval);
        Add(args, "watchLog", WatchLog);
        Add(args, "watchTmp", WatchTmp);
        Add(args, "watchTimeout", Unlimited(WatchTimeout));
        Add(args, "stallTimeout", Unlimited(StallTimeout));
        Add(args, "clean", CleanOnSuccess);
        Add(args, "killOnTimeout", KillOnTimeout);
        Add(args, "killOnStall", KillOnStall);
        Add(args, "severity", Severity?.ToString());
        Add(args, "writeEvents", WriteEvents);
        return args;
    }

    /// <summary>Appends <c>--flag:value</c> unless the value is <see langword="null"/>.</summary>
    private static void Add(List<string> args, string flag, string? value)
    {
        if (value is not null)
        {
            args.Add($"--{flag}:{value}");
        }
    }

    /// <summary>Appends a Boolean flag as TRNRun's lowercase <c>true</c> or <c>false</c>, unless unset.</summary>
    private static void Add(List<string> args, string flag, bool? value) =>
        Add(args, flag, value switch { null => null, true => "true", false => "false" });

    /// <summary>Appends a duration flag in whole milliseconds, rounded up so a short timeout never becomes unlimited, unless unset.</summary>
    private static void Add(List<string> args, string flag, TimeSpan? value) =>
        Add(args, flag, value is { } duration ? ((long)Math.Ceiling(duration.TotalMilliseconds)).ToString(CultureInfo.InvariantCulture) : null);

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
