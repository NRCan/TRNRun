namespace TRNRun;

/// <summary>trnrund exited, was closed, or answered outside its protocol.</summary>
public sealed class DaemonException : Exception
{
    /// <summary>Creates the exception with its message and, for an exit, its code and diagnostics.</summary>
    /// <param name="message">What went wrong.</param>
    /// <param name="exitCode">trnrund's exit code, if it exited.</param>
    /// <param name="diagnostics">What trnrund wrote to stderr before exiting, if anything.</param>
    public DaemonException(string message, int? exitCode = null, string? diagnostics = null)
        : base(message)
    {
        ExitCode = exitCode;
        Diagnostics = diagnostics ?? "";
    }

    /// <summary>trnrund's exit code, or <see langword="null"/> if it did not exit.</summary>
    public int? ExitCode { get; }

    /// <summary>What trnrund wrote to stderr before exiting; empty if nothing.</summary>
    public string Diagnostics { get; }
}

/// <summary>SQLite failed to open or read a trnrund database.</summary>
public sealed class DatabaseException : Exception
{
    /// <summary>Creates the exception with SQLite's message and extended result code.</summary>
    /// <param name="message">SQLite's description of the failure.</param>
    /// <param name="resultCode">SQLite's extended result code.</param>
    public DatabaseException(string message, int resultCode)
        : base(message)
    {
        ResultCode = resultCode;
    }

    /// <summary>SQLite's extended result code, such as 14 (<c>SQLITE_CANTOPEN</c>).</summary>
    public int ResultCode { get; }
}
