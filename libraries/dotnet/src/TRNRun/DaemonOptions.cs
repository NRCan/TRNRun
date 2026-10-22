namespace TRNRun;

/// <summary>How <see cref="Daemon.Start"/> starts trnrund.</summary>
/// <remarks>Relative paths resolve from the current working directory when the daemon starts.</remarks>
public sealed record DaemonOptions
{
    /// <summary>Database holding the runs, created if missing in an existing directory; by default a temporary one deleted on disposal.</summary>
    public string? DatabasePath { get; init; }

    /// <summary>Simulations run at once; <see langword="null"/>, the default, means the CPU count minus one, at least 1.</summary>
    public int? MaxConcurrent { get; init; }

    /// <summary>trnrund executable; by default the trnrund.exe bundled in <c>native/</c> beside the application.</summary>
    public string TrnrundPath { get; init; } = Path.Combine(AppContext.BaseDirectory, "native", "trnrund.exe");

    /// <summary>TRNRun executable every run is started with; by default the trnrun.exe bundled in <c>native/</c> beside the application.</summary>
    public string TrnrunPath { get; init; } = Path.Combine(AppContext.BaseDirectory, "native", "trnrun.exe");

    /// <summary>How long a request waits for trnrund's reply before throwing <see cref="TimeoutException"/>; 60 seconds by default.</summary>
    public TimeSpan RequestTimeout { get; init; } = TimeSpan.FromSeconds(60);
}
