namespace TRNRun;

/// <summary>trnrund has ended normally, after a shutdown, a clean exit, or disposal, so it no longer answers.</summary>
/// <remarks>Calling a member after <see cref="Daemon.Dispose"/> throws <see cref="ObjectDisposedException"/> instead.</remarks>
public sealed class DaemonClosedException : TrnrunException
{
    /// <summary>Creates the exception with a default message.</summary>
    public DaemonClosedException()
    {
    }

    /// <summary>Creates the exception with its message.</summary>
    public DaemonClosedException(string message)
        : base(message)
    {
    }

    /// <summary>Creates the exception with its message and the exception that caused it.</summary>
    public DaemonClosedException(string message, Exception innerException)
        : base(message, innerException)
    {
    }
}
