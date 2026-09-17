using System.Globalization;
using TRNRun.Internal;

namespace TRNRun;

/// <summary>Specifies how the native runner displays the TRNSYS windows.</summary>
public enum GuiVisibility
{
    /// <summary>Shows the windows and leaves them open after the simulation.</summary>
    KeepOpen,
    /// <summary>Shows the windows and closes them after the simulation.</summary>
    AutoClose,
    /// <summary>Minimizes the windows after launch and leaves them open after the simulation.</summary>
    Minimized,
    /// <summary>Minimizes the windows after launch and closes them after the simulation.</summary>
    MinimizedAuto,
    /// <summary>Hides the windows and closes TRNSYS after the simulation.</summary>
    Hidden,
}

/// <summary>Specifies the minimum severity of emitted TRNSYS log entries.</summary>
public enum LogSeverity
{
    /// <summary>Emits notice, warning, and fatal entries.</summary>
    Notice,
    /// <summary>Emits warning and fatal entries.</summary>
    Warning,
    /// <summary>Emits only fatal entries.</summary>
    Fatal,
}

/// <summary>
/// Immutable launch, monitoring, and output settings for TRNSYS simulations.
/// </summary>
/// <remarks>
/// <para>
/// Reuse an instance across runs; use a <c>with</c> expression to create a modified copy.
/// Settings are validated by <see cref="SimulationManager.Add"/> or explicitly with
/// <see cref="Validate"/>. Supply unquoted paths; relative paths resolve against the
/// working directory at validation.
/// </para>
/// <para>
/// Durations must be whole milliseconds from 0 through 2,147,483,647, with
/// <see cref="PollInterval"/> at least 1 millisecond. Null or zero timeouts mean
/// unlimited detection or monitoring, or disabled stall detection.
/// </para>
/// <para>
/// Stall detection requires <see cref="WatchTmp"/> and valid Type3830 progress.
/// Enable <see cref="KillOnTimeout"/> or <see cref="KillOnStall"/> to terminate TRNSYS
/// on the corresponding condition; otherwise, waiting and shutdown can block indefinitely.
/// </para>
/// </remarks>
public sealed record SimulationConfig
{
    /// <summary>Runner executable path, or null to use bundled trnrun.exe.</summary>
    public string? TrnRunPath { get; init; }
    /// <summary>Installed TRNSYS executable path.</summary>
    public string TrnExePath { get; init; } = @"C:\TRNSYS18\Exe\TrnEXE64.exe";
    /// <summary>TRNSYS window visibility and automatic closing behavior.</summary>
    public GuiVisibility GuiVisibility { get; init; } = GuiVisibility.Hidden;
    /// <summary>Whether to wait for the TRNSYS GUI, even when hidden.</summary>
    public bool WaitForGui { get; init; } = true;
    /// <summary>Whether to wait for the component-order header in the listing file.</summary>
    public bool WaitForLst { get; init; } = true;
    /// <summary>Whether to wait for the Type3830 progress file.</summary>
    public bool WaitForTmp { get; init; }
    /// <summary>Readiness timeout, excluding launch-mutex waiting and extra delay.</summary>
    public TimeSpan? DetectionTimeout { get; init; } = TimeSpan.FromMinutes(5);
    /// <summary>Delay after readiness detection, while the launch mutex remains held.</summary>
    public TimeSpan ExtraDelay { get; init; } = TimeSpan.Zero;
    /// <summary>Runtime-monitoring poll interval, independent of readiness detection.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromMilliseconds(100);
    /// <summary>Whether to stream log events; the final fatal-error check always runs.</summary>
    public bool WatchLog { get; init; } = true;
    /// <summary>Whether to monitor Type3830 progress for updates, stalls, and cancellation.</summary>
    public bool WatchTmp { get; init; }
    /// <summary>Timeout measured from the start of runtime monitoring.</summary>
    public TimeSpan? WatchTimeout { get; init; }
    /// <summary>Maximum wall-clock duration without simulation-time progress.</summary>
    public TimeSpan? StallTimeout { get; init; }
    /// <summary>Whether successful runs delete their .tmp, .log, .lst, and .PTI artifacts.</summary>
    public bool CleanOnSuccess { get; init; }
    /// <summary>Whether to terminate TRNSYS on a detection or monitoring timeout.</summary>
    public bool KillOnTimeout { get; init; }
    /// <summary>Whether to terminate TRNSYS when a stall is detected.</summary>
    public bool KillOnStall { get; init; }
    /// <summary>Minimum emitted log severity.</summary>
    public LogSeverity Severity { get; init; } = LogSeverity.Notice;
    /// <summary>Whether to write events to the deck's .jsonl file, replacing any existing file.</summary>
    public bool WriteEvents { get; init; }

    /// <summary>Validates settings and executable paths without modifying the configuration or launching a process.</summary>
    /// <remarks>
    /// Checks enum values, whole-millisecond duration limits, and existing TRNSYS and runner executables.
    /// A null runner path uses bundled discovery. Deck validation is handled separately by the manager.
    /// </remarks>
    /// <exception cref="ArgumentException">An executable path is empty, malformed, or not an .exe.</exception>
    /// <exception cref="ArgumentOutOfRangeException">An enum value or duration is invalid.</exception>
    /// <exception cref="FileNotFoundException">A required executable cannot be found.</exception>
    public void Validate()
    {
        ValidateEnum(GuiVisibility, nameof(GuiVisibility), "Unknown GUI visibility.");
        ValidateEnum(Severity, nameof(Severity), "Unknown log severity.");
        ValidateDuration(DetectionTimeout, nameof(DetectionTimeout));
        ValidateDuration(ExtraDelay, nameof(ExtraDelay));
        ValidateDuration(PollInterval, nameof(PollInterval), requirePositive: true);
        ValidateDuration(WatchTimeout, nameof(WatchTimeout));
        ValidateDuration(StallTimeout, nameof(StallTimeout));

        _ = ExecutableResolver.Validate(TrnExePath, nameof(TrnExePath));
        _ = ExecutableResolver.Resolve(TrnRunPath, "trnrun.exe");
    }

    /// <summary>Validates the configuration and converts it to native runner arguments.</summary>
    /// <returns>Unquoted argument strings for the queue request's runnerArgs array.</returns>
    /// <remarks>
    /// Uses invariant whole milliseconds and native enum/boolean spellings. The manager supplies
    /// the runner executable separately; the queue adds the deck path and run ID.
    /// </remarks>
    internal string[] ToCliArgs()
    {
        Validate();

        string visibility = GuiVisibility switch
        {
            GuiVisibility.KeepOpen => "keepOpen",
            GuiVisibility.AutoClose => "autoClose",
            GuiVisibility.Minimized => "minimized",
            GuiVisibility.MinimizedAuto => "minimizedAuto",
            GuiVisibility.Hidden => "hidden",
            _ => throw new ArgumentOutOfRangeException(
                nameof(GuiVisibility),
                GuiVisibility,
                "Unknown GUI visibility."
            ),
        };

        return
        [
            "--trnexePath:" + Path.GetFullPath(TrnExePath),
            "--guiVisibility:" + visibility,
            "--waitForGui:" + ToBoolean(WaitForGui),
            "--waitForLst:" + ToBoolean(WaitForLst),
            "--waitForTmp:" + ToBoolean(WaitForTmp),
            "--detectTimeout:" + ToMilliseconds(DetectionTimeout),
            "--extraDelay:" + ToMilliseconds(ExtraDelay),
            "--pollMs:" + ToMilliseconds(PollInterval),
            "--watchLog:" + ToBoolean(WatchLog),
            "--watchTmp:" + ToBoolean(WatchTmp),
            "--watchTimeout:" + ToMilliseconds(WatchTimeout),
            "--stallTimeout:" + ToMilliseconds(StallTimeout),
            "--clean:" + ToBoolean(CleanOnSuccess),
            "--killOnTimeout:" + ToBoolean(KillOnTimeout),
            "--killOnStall:" + ToBoolean(KillOnStall),
            "--severity:" + Severity.ToString(),
            "--writeEvents:" + ToBoolean(WriteEvents),
        ];
    }

    private static void ValidateEnum<TEnum>(TEnum value, string paramName, string message)
        where TEnum : struct, Enum
    {
        if (!Enum.IsDefined(value))
        {
            throw new ArgumentOutOfRangeException(paramName, value, message);
        }
    }

    private static void ValidateDuration(
        TimeSpan? value,
        string paramName,
        bool requirePositive = false
    )
    {
        // Tick arithmetic avoids rounding fractional milliseconds or overflowing native wait limits.
        long ticks = value?.Ticks ?? 0;
        int minimumMs = requirePositive ? 1 : 0;

        if (
            ticks < minimumMs * TimeSpan.TicksPerMillisecond
            || ticks > (long)int.MaxValue * TimeSpan.TicksPerMillisecond
            || ticks % TimeSpan.TicksPerMillisecond != 0
        )
        {
            throw new ArgumentOutOfRangeException(
                paramName,
                value,
                $"Must be a whole number of milliseconds from {minimumMs} through 2,147,483,647."
            );
        }
    }

    private static string ToMilliseconds(TimeSpan? value) =>
        ((value?.Ticks ?? 0) / TimeSpan.TicksPerMillisecond).ToString(CultureInfo.InvariantCulture);

    private static string ToBoolean(bool value) => value ? "true" : "false";
}
