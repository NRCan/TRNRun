namespace TRNRun;

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
