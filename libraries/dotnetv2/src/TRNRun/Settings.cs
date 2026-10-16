using System.Globalization;

namespace TRNRun;

/// <summary>TRNSYS window behavior, passed as <c>--guiVisibility</c>.</summary>
public enum GuiVisibility
{
    /// <summary>Stays visible and open after the run.</summary>
    KeepOpen,
    /// <summary>Stays visible and closes after the run.</summary>
    AutoClose,
    /// <summary>Stays minimized and open after the run.</summary>
    Minimized,
    /// <summary>Stays minimized and closes after the run.</summary>
    MinimizedAuto,
    /// <summary>Has no window and closes after the run.</summary>
    Hidden,
}

/// <summary>Minimum emitted log severity, passed as <c>--severity</c>.</summary>
public enum LogSeverity
{
    /// <summary>Emits notice, warning and fatal entries.</summary>
    Notice,
    /// <summary>Emits warning and fatal entries.</summary>
    Warning,
    /// <summary>Emits only fatal entries.</summary>
    Fatal,
}

/// <summary>TRNRun options for a simulation, with named, typed properties.</summary>
/// <remarks>
/// <para>
/// Each property maps to a trnrun.exe command-line flag, noted in its documentation, passed as
/// <c>--name:value</c>. A property left <see langword="null"/> is not passed, so TRNRun's own
/// default applies; run <c>trnrun.exe --help</c> for them. <c>new SimulationSettings()</c>
/// therefore passes nothing. The trnrun.exe executable itself is chosen per
/// <see cref="Daemon"/>, since one daemon runs every simulation with the same runner. Relative
/// paths are interpreted from the current working directory.
/// </para>
/// <para>
/// trnrund checks the values with TRNRun's own parser when a run is added.
/// <see cref="ToCliArgs"/> checks that a set <see cref="TrnexePath"/> exists, so a missing
/// installation fails before runs are queued.
/// </para>
/// </remarks>
public sealed record SimulationSettings
{
    /// <summary>
    /// Path to the TRNSYS executable (TrnEXE64.exe or TrnEXE.exe), passed as <c>--trnexePath</c>.
    /// Set it unless your installation matches TRNRun's default.
    /// </summary>
    public string? TrnexePath { get; init; }

    /// <summary>TRNSYS window behavior (<c>--guiVisibility</c>).</summary>
    public GuiVisibility? GuiVisibility { get; init; }

    /// <summary>
    /// Wait for a TRNSYS GUI during launch detection (<c>--waitForGui</c>). Detection determines
    /// when startup has completed so the global launch mutex can be released for the next
    /// simulation.
    /// </summary>
    public bool? WaitForGui { get; init; }

    /// <summary>
    /// Wait for the component-order header in the <c>.lst</c> file during launch detection
    /// (<c>--waitForLst</c>).
    /// </summary>
    public bool? WaitForLst { get; init; }

    /// <summary>
    /// Wait for the <c>.tmp</c> file during launch detection (<c>--waitForTmp</c>). Requires a
    /// Progress Tracker (Type3830) in the deck.
    /// </summary>
    public bool? WaitForTmp { get; init; }

    /// <summary>
    /// Shared launch-detection timeout in milliseconds (<c>--detectTimeout</c>); 0 means
    /// unlimited. If <see cref="KillOnTimeout"/> is enabled and TRNSYS is still running,
    /// expiration yields <c>TIMEOUT</c>; otherwise detection proceeds into monitoring. Detection
    /// holds the session-wide launch mutex. This deadline excludes <see cref="ExtraDelayMs"/>
    /// and is not a total mutex-hold limit.
    /// </summary>
    public int? DetectTimeoutMs { get; init; }

    /// <summary>Additional delay after detection passes (<c>--extraDelay</c>), in milliseconds.</summary>
    public int? ExtraDelayMs { get; init; }

    /// <summary>
    /// Output-file and process polling interval (<c>--pollMs</c>), in milliseconds. The runner
    /// clamps it to at least 1 and raises positive watch and stall timeouts shorter than this
    /// interval to this interval.
    /// </summary>
    public int? PollMs { get; init; }

    /// <summary>Stream <c>.log</c> entries as LOG events (<c>--watchLog</c>).</summary>
    public bool? WatchLog { get; init; }

    /// <summary>
    /// Stream <c>.tmp</c> updates as CONFIG and PROGRESS events (<c>--watchTmp</c>). Requires
    /// Type3830. Also gates progress-derived <c>CANCELLED</c> and <c>STALLED</c> outcomes.
    /// Without it, an early exit without another detected failure is reported as <c>DONE</c>.
    /// </summary>
    public bool? WatchTmp { get; init; }

    /// <summary>
    /// Runtime-monitoring timeout (<c>--watchTimeout</c>), in milliseconds; 0 means unlimited.
    /// Expiration corresponds to <c>TIMEOUT</c> and exit code 124.
    /// </summary>
    public int? WatchTimeoutMs { get; init; }

    /// <summary>
    /// Maximum wall-clock milliseconds without simulation-time progress (<c>--stallTimeout</c>);
    /// 0 disables the check. Requires <see cref="WatchTmp"/>. A stall yields <c>STALLED</c> and
    /// exit code 125.
    /// </summary>
    public int? StallTimeoutMs { get; init; }

    /// <summary>Delete <c>.tmp</c>, <c>.log</c>, <c>.lst</c> and <c>.PTI</c> artifacts on success (<c>--clean</c>).</summary>
    public bool? CleanOnSuccess { get; init; }

    /// <summary>
    /// Kill TRNSYS on a detection or watch timeout (<c>--killOnTimeout</c>). Otherwise detection
    /// proceeds into monitoring; after a watch timeout, the runner waits for TRNSYS to exit.
    /// </summary>
    public bool? KillOnTimeout { get; init; }

    /// <summary>
    /// Kill TRNSYS when a stall is detected (<c>--killOnStall</c>). Otherwise the runner waits
    /// for TRNSYS to exit.
    /// </summary>
    public bool? KillOnStall { get; init; }

    /// <summary>Minimum emitted log severity (<c>--severity</c>).</summary>
    public LogSeverity? Severity { get; init; }

    /// <summary>
    /// Write emitted events to a <c>.jsonl</c> file beside the deck (<c>--writeEvents</c>). For
    /// example, model.dck writes model.jsonl, replacing any existing file when the run starts.
    /// </summary>
    public bool? WriteEvents { get; init; }

    /// <summary>Returns unquoted argv entries for the properties that are set, with <see cref="TrnexePath"/> made absolute.</summary>
    /// <exception cref="FileNotFoundException">A set <see cref="TrnexePath"/> is not an existing file.</exception>
    /// <exception cref="ArgumentOutOfRangeException">An enum property holds an undefined value.</exception>
    public IReadOnlyList<string> ToCliArgs()
    {
        var args = new List<string>();
        Add(args, "trnexePath", TrnexePath is null ? null : ResolveTrnexe(TrnexePath));
        Add(args, "guiVisibility", GuiVisibility is { } visibility ? GuiVisibilityName(visibility) : null);
        Add(args, "waitForGui", WaitForGui);
        Add(args, "waitForLst", WaitForLst);
        Add(args, "waitForTmp", WaitForTmp);
        Add(args, "detectTimeout", DetectTimeoutMs);
        Add(args, "extraDelay", ExtraDelayMs);
        Add(args, "pollMs", PollMs);
        Add(args, "watchLog", WatchLog);
        Add(args, "watchTmp", WatchTmp);
        Add(args, "watchTimeout", WatchTimeoutMs);
        Add(args, "stallTimeout", StallTimeoutMs);
        Add(args, "clean", CleanOnSuccess);
        Add(args, "killOnTimeout", KillOnTimeout);
        Add(args, "killOnStall", KillOnStall);
        Add(args, "severity", Severity is { } severity ? SeverityName(severity) : null);
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

    /// <summary>Appends an integer flag in invariant culture, unless unset.</summary>
    private static void Add(List<string> args, string flag, int? value) =>
        Add(args, flag, value?.ToString(CultureInfo.InvariantCulture));

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
        TRNRun.GuiVisibility.KeepOpen => "keepOpen",
        TRNRun.GuiVisibility.AutoClose => "autoClose",
        TRNRun.GuiVisibility.Minimized => "minimized",
        TRNRun.GuiVisibility.MinimizedAuto => "minimizedAuto",
        TRNRun.GuiVisibility.Hidden => "hidden",
        _ => throw new ArgumentOutOfRangeException(nameof(GuiVisibility), value, "Unknown GUI visibility."),
    };

    /// <summary>Returns TRNRun's keyword for a log severity.</summary>
    private static string SeverityName(LogSeverity value) => value switch
    {
        LogSeverity.Notice => "Notice",
        LogSeverity.Warning => "Warning",
        LogSeverity.Fatal => "Fatal",
        _ => throw new ArgumentOutOfRangeException(nameof(Severity), value, "Unknown log severity."),
    };
}

/// <summary>trnrund options for a daemon; <see cref="Daemon"/> builds one from its parameters.</summary>
/// <remarks>
/// Each property maps to a trnrund.exe flag passed as <c>--name:value</c>; one left
/// <see langword="null"/> is not passed, so trnrund's own default applies. trnrund checks the
/// values when it starts, and exits with a usage error for a missing TRNRun or a
/// <see cref="MaxConcurrent"/> below 1.
/// </remarks>
/// <param name="TrnrunPath">TRNRun executable every run is started with (<c>--trnrun</c>).</param>
/// <param name="MaxConcurrent">Simulations run at once (<c>--maxConcurrent</c>).</param>
/// <param name="DatabasePath">SQLite database holding every run's state and logs (<c>--database</c>).</param>
internal sealed record DaemonSettings(string? TrnrunPath = null, int? MaxConcurrent = null, string? DatabasePath = null)
{
    /// <summary>Returns unquoted argv entries for the properties that are set, with paths made absolute but not checked.</summary>
    internal IReadOnlyList<string> ToCliArgs()
    {
        var args = new List<string>();
        if (TrnrunPath is not null)
        {
            args.Add($"--trnrun:{Path.GetFullPath(TrnrunPath)}");
        }

        if (MaxConcurrent is { } maxConcurrent)
        {
            args.Add($"--maxConcurrent:{maxConcurrent.ToString(CultureInfo.InvariantCulture)}");
        }

        if (DatabasePath is not null)
        {
            args.Add($"--database:{Path.GetFullPath(DatabasePath)}");
        }

        return args;
    }
}
