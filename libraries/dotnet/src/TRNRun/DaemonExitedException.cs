using System.Globalization;

namespace TRNRun;

/// <summary>trnrund exited on its own, such as after a crash or a startup failure.</summary>
public sealed class DaemonExitedException : TrnrunException
{
    /// <summary>Describes an exit from its code and diagnostics.</summary>
    /// <param name="exitCode">trnrund's exit code, or <see langword="null"/> if it closed its output without exiting.</param>
    /// <param name="diagnostics">What trnrund wrote to stderr before exiting; empty if nothing.</param>
    public DaemonExitedException(int? exitCode, string diagnostics)
        : base(Describe(exitCode, diagnostics))
    {
        ExitCode = exitCode;
        Diagnostics = diagnostics;
    }

    /// <summary>trnrund's exit code, or <see langword="null"/> if it closed its output without exiting.</summary>
    public int? ExitCode { get; }

    /// <summary>What trnrund wrote to stderr before exiting; empty if nothing.</summary>
    public string Diagnostics { get; }

    /// <summary>Returns the message for an exit.</summary>
    private static string Describe(int? exitCode, string diagnostics)
    {
        string message = exitCode is null
            ? "trnrund closed its output but did not exit"
            : string.Create(CultureInfo.InvariantCulture, $"trnrund exited with code {exitCode}");
        return diagnostics.Length > 0 ? $"{message}: {diagnostics}" : message;
    }
}
