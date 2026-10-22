namespace TRNRun;

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
