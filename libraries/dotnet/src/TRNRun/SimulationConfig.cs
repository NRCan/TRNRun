using System.Globalization;

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

/// <summary>Launch, monitoring, and output settings for a simulation.</summary>
/// <remarks>
/// Settings are validated when submitted. Paths must be unquoted, and durations must be whole
/// milliseconds. Timeout and stall handling can wait indefinitely when process termination is disabled.
/// </remarks>
public sealed record SimulationConfig
{
    /// <summary>Runner executable path, or <see langword="null"/> to discover bundled <c>trnrun.exe</c>.</summary>
    public string? TrnRunPath { get; init; }

    /// <summary>Installed TRNSYS executable path.</summary>
    public string TrnExePath { get; init; } = @"C:\TRNSYS18\Exe\TrnEXE64.exe";

    /// <summary>TRNSYS window visibility and automatic closing behavior.</summary>
    public GuiVisibility GuiVisibility { get; init; } = GuiVisibility.Hidden;

    /// <summary>Waits for the TRNSYS window during launch, including in hidden mode.</summary>
    public bool WaitForGui { get; init; } = true;

    /// <summary>Waits for the component-order header in the deck's <c>.lst</c> file during launch.</summary>
    public bool WaitForLst { get; init; } = true;

    /// <summary>Waits for the Type3830 <c>.tmp</c> file to exist during launch; does not enable progress monitoring.</summary>
    public bool WaitForTmp { get; init; }

    /// <summary>Shared readiness timeout, excluding mutex waiting and extra delay; <see langword="null"/> or zero means unlimited.</summary>
    public TimeSpan? DetectionTimeout { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>Delay after readiness succeeds, while the launch mutex remains held.</summary>
    public TimeSpan ExtraDelay { get; init; } = TimeSpan.Zero;

    /// <summary>Runtime poll interval and minimum positive watch/stall timeout; independent of readiness checks.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromMilliseconds(100);

    /// <summary>Streams TRNSYS log events; when disabled, fatal checks still run at process exit unless monitoring has already stopped.</summary>
    public bool WatchLog { get; init; } = true;

    /// <summary>Reads Type3830 <c>.tmp</c> snapshots for progress events, stall detection, and incomplete-run detection.</summary>
    public bool WatchTmp { get; init; }

    /// <summary>Timeout from the start of runtime monitoring; <see langword="null"/> or zero means unlimited.</summary>
    public TimeSpan? WatchTimeout { get; init; }

    /// <summary>No-progress timeout requiring <see cref="WatchTmp"/> and valid, incomplete Type3830 progress; null or zero disables it.</summary>
    public TimeSpan? StallTimeout { get; init; }

    /// <summary>Deletes .tmp, .log, .lst, and .PTI files after success; stale copies are always removed before launch.</summary>
    public bool CleanOnSuccess { get; init; }

    /// <summary>Terminates TRNSYS on a launch-readiness or runtime-monitoring timeout.</summary>
    public bool KillOnTimeout { get; init; }

    /// <summary>Terminates TRNSYS when a stall is detected.</summary>
    public bool KillOnStall { get; init; }

    /// <summary>Minimum severity for emitted log events; does not affect fatal-error detection.</summary>
    public LogSeverity Severity { get; init; } = LogSeverity.Notice;

    /// <summary>Writes runner events to the deck's <c>.jsonl</c> file, truncating any existing file at run start.</summary>
    public bool WriteEvents { get; init; }

    /// <summary>Validates and converts the settings to native command-line arguments.</summary>
    internal string[] ToCliArgs(out string runnerPath)
    {
        ValidateDuration(DetectionTimeout, nameof(DetectionTimeout));
        ValidateDuration(ExtraDelay, nameof(ExtraDelay));
        ValidateDuration(PollInterval, nameof(PollInterval), requirePositive: true);
        ValidateDuration(WatchTimeout, nameof(WatchTimeout));
        ValidateDuration(StallTimeout, nameof(StallTimeout));

        string trnExePath = ResolveExecutable(TrnExePath, "TRNSYS", nameof(TrnExePath));

        // An explicit path never falls back to the executable bundled in native/.
        runnerPath = ResolveExecutable(
            TrnRunPath ?? Path.Combine(AppContext.BaseDirectory, "native", "trnrun.exe"),
            "Runner",
            nameof(TrnRunPath)
        );

        return
        [
            "--trnexePath:" + trnExePath,
            "--guiVisibility:" + ToGuiVisibility(GuiVisibility, nameof(GuiVisibility)),
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
            "--severity:" + ToSeverity(Severity, nameof(Severity)),
            "--writeEvents:" + ToBoolean(WriteEvents),
        ];
    }

    /// <summary>Resolves and validates an executable path.</summary>
    private static string ResolveExecutable(string path, string name, string paramName)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(path, paramName);

        string fullPath = Path.GetFullPath(path);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException(
                $"{name} executable not found: '{fullPath}'.",
                fullPath
            );
        }

        return fullPath;
    }

    /// <summary>Validates a duration against native millisecond limits.</summary>
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
                $"Must be a whole number of milliseconds from {minimumMs} through {int.MaxValue:N0}."
            );
        }
    }

<<<<<<< HEAD
    /// <summary>Formats a GUI visibility as its native CLI keyword.</summary>
    private static string ToGuiVisibility(GuiVisibility value, string paramName) => value switch
=======
    /// <summary>Converts GUI visibility to its native value.</summary>
    private static string ToCliValue(
        GuiVisibility value,
        [CallerArgumentExpression(nameof(value))] string? paramName = null
    ) => value switch
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
    {
        GuiVisibility.KeepOpen => "keepOpen",
        GuiVisibility.AutoClose => "autoClose",
        GuiVisibility.Minimized => "minimized",
        GuiVisibility.MinimizedAuto => "minimizedAuto",
        GuiVisibility.Hidden => "hidden",
        _ => throw new ArgumentOutOfRangeException(paramName, value, "Unknown GUI visibility."),
    };

<<<<<<< HEAD
    /// <summary>Formats a log severity as its native CLI keyword.</summary>
    private static string ToSeverity(LogSeverity value, string paramName) => value switch
=======
    /// <summary>Converts log severity to its native value.</summary>
    private static string ToCliValue(
        LogSeverity value,
        [CallerArgumentExpression(nameof(value))] string? paramName = null
    ) => value switch
>>>>>>> ca8acfadef06eb4112b9effb7bab438856a0fdc8
    {
        LogSeverity.Notice => "Notice",
        LogSeverity.Warning => "Warning",
        LogSeverity.Fatal => "Fatal",
        _ => throw new ArgumentOutOfRangeException(paramName, value, "Unknown log severity."),
    };

    /// <summary>Formats a duration as whole milliseconds.</summary>
    private static string ToMilliseconds(TimeSpan? value) =>
        ((value?.Ticks ?? 0) / TimeSpan.TicksPerMillisecond)
            .ToString(CultureInfo.InvariantCulture);

    /// <summary>Formats a Boolean as a lowercase native value.</summary>
    private static string ToBoolean(bool value) => value ? "true" : "false";
}
