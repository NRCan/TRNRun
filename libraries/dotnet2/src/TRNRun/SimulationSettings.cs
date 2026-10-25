using System.Globalization;

namespace TRNRun;

/// <summary>TRNRun options for a simulation; each property maps to the trnrun.exe flag in its doc.</summary>
/// <remarks>
/// A <see langword="null"/> property is not passed, so TRNRun's default applies (<c>trnrun.exe --help</c>).
/// Durations pass as whole milliseconds, rounded up; an infinite or zero timeout is unlimited.
/// Relative paths resolve from the current directory, and trnrund validates values when a run is added.
/// </remarks>
public sealed record SimulationSettings
{
    /// <summary>TRNSYS executable, TrnEXE64.exe or TrnEXE.exe (<c>--trnexePath</c>).</summary>
    public string? TrnexePath { get; init; }

    /// <summary>TRNSYS window behavior (<c>--guiVisibility</c>).</summary>
    public GuiVisibility? GuiVisibility { get; init; }

    /// <summary>Wait for the TRNSYS GUI during launch detection (<c>--waitForGui</c>).</summary>
    public bool? WaitForGui { get; init; }

    /// <summary>Wait for the <c>.lst</c> component-order header during launch detection (<c>--waitForLst</c>).</summary>
    public bool? WaitForLst { get; init; }

    /// <summary>Wait for the <c>.tmp</c> file during launch detection; requires Type3830 (<c>--waitForTmp</c>).</summary>
    public bool? WaitForTmp { get; init; }

    /// <summary>Launch-detection timeout, excluding <see cref="ExtraDelay"/> (<c>--detectTimeout</c>).</summary>
    public TimeSpan? DetectTimeout { get; init; }

    /// <summary>Delay after detection passes (<c>--extraDelay</c>).</summary>
    public TimeSpan? ExtraDelay { get; init; }

    /// <summary>Output-file and process polling interval, at least 1 ms (<c>--pollMs</c>).</summary>
    public TimeSpan? PollInterval { get; init; }

    /// <summary>Stream <c>.log</c> entries as LOG events (<c>--watchLog</c>).</summary>
    public bool? WatchLog { get; init; }

    /// <summary>Stream <c>.tmp</c> updates as CONFIG and PROGRESS events, and detect stalls; requires Type3830 (<c>--watchTmp</c>).</summary>
    public bool? WatchTmp { get; init; }

    /// <summary>Runtime-monitoring timeout, ending in <c>TIMEOUT</c> (<c>--watchTimeout</c>).</summary>
    public TimeSpan? WatchTimeout { get; init; }

    /// <summary>Longest time without simulation progress before <c>STALLED</c>; requires <see cref="WatchTmp"/> (<c>--stallTimeout</c>).</summary>
    public TimeSpan? StallTimeout { get; init; }

    /// <summary>Delete <c>.tmp</c>, <c>.log</c>, <c>.lst</c> and <c>.PTI</c> artifacts on success (<c>--clean</c>).</summary>
    public bool? CleanOnSuccess { get; init; }

    /// <summary>Kill TRNSYS on a detection or watch timeout instead of waiting for it (<c>--killOnTimeout</c>).</summary>
    public bool? KillOnTimeout { get; init; }

    /// <summary>Kill TRNSYS on a stall instead of waiting for it (<c>--killOnStall</c>).</summary>
    public bool? KillOnStall { get; init; }

    /// <summary>Minimum emitted log severity (<c>--severity</c>).</summary>
    public LogSeverity? Severity { get; init; }

    /// <summary>Write emitted events to a <c>.jsonl</c> file beside the deck (<c>--writeEvents</c>).</summary>
    public bool? WriteEvents { get; init; }

    /// <summary>Returns unquoted argv entries for the properties that are set, with <see cref="TrnexePath"/> made absolute.</summary>
    /// <exception cref="FileNotFoundException">A set <see cref="TrnexePath"/> is not an existing file.</exception>
    /// <exception cref="ArgumentOutOfRangeException"><see cref="GuiVisibility"/> holds an undefined value; trnrund refuses any other bad value.</exception>
    public IReadOnlyList<string> ToCliArgs()
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

    /// <summary>Returns TRNRun's unlimited, zero, for <see cref="Timeout.InfiniteTimeSpan"/>.</summary>
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

    /// <summary>Returns TRNRun's keyword for a window behavior.</summary>
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
