using System.Globalization;

namespace TRNRun;

// The exceptions TRNRun throws, so callers can tell them apart without reading messages.

/// <summary>Base class of every exception TRNRun throws itself; thrown as is when trnrund answers outside its protocol.</summary>
public class TrnrunException : Exception
{
    /// <summary>Creates the exception with a default message.</summary>
    public TrnrunException()
    {
    }

    /// <summary>Creates the exception with its message.</summary>
    public TrnrunException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with its message and the exception that caused it.</summary>
    public TrnrunException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>trnrund exited on its own, such as after a crash or a startup failure.</summary>
public sealed class DaemonExitedException : TrnrunException
{
    /// <summary>Creates the exception with a default message and no exit details.</summary>
    public DaemonExitedException()
    {
    }

    /// <summary>Creates the exception with its message and no exit details.</summary>
    public DaemonExitedException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with its message, the exception that caused it, and no exit details.</summary>
    public DaemonExitedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }

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
    public string Diagnostics { get; } = "";

    /// <summary>Returns the message for an exit.</summary>
    private static string Describe(int? exitCode, string diagnostics)
    {
        string message = exitCode is null
            ? "trnrund closed its output but did not exit"
            : string.Create(CultureInfo.InvariantCulture, $"trnrund exited with code {exitCode}");
        return diagnostics.Length > 0 ? $"{message}: {diagnostics}" : message;
    }
}

/// <summary>trnrund refused a request, such as a run with a missing deck or an unknown run ID.</summary>
public sealed class RequestRejectedException : TrnrunException
{
    /// <summary>Creates the exception with a default message.</summary>
    public RequestRejectedException()
    {
    }

    /// <summary>Creates the exception with trnrund's reason.</summary>
    public RequestRejectedException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with its message and the exception that caused it.</summary>
    public RequestRejectedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>trnrund has ended normally, after a shutdown, a clean exit, or disposal, so it no longer answers.</summary>
/// <remarks>Calling a member after <see cref="Daemon.Dispose"/> throws <see cref="ObjectDisposedException"/> instead.</remarks>
public sealed class ClosedException : TrnrunException
{
    /// <summary>Creates the exception with a default message.</summary>
    public ClosedException()
    {
    }

    /// <summary>Creates the exception with its message.</summary>
    public ClosedException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with its message and the exception that caused it.</summary>
    public ClosedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}

/// <summary>The database has a schema version this package does not read.</summary>
public sealed class SchemaVersionException : TrnrunException
{
    /// <summary>Creates the exception with a default message.</summary>
    public SchemaVersionException()
    {
    }

    /// <summary>Creates the exception with its message.</summary>
    public SchemaVersionException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with its message and the exception that caused it.</summary>
    public SchemaVersionException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
