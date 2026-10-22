namespace TRNRun;

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
