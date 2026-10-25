namespace TRNRun;

/// <summary>Base class of the exceptions this library throws; thrown itself when trnrund answers outside its JSON protocol.</summary>
/// <param name="message">What went wrong.</param>
/// <param name="innerException">The failure that caused it, if any.</param>
public class TRNRunException(string message, Exception? innerException = null) : Exception(message, innerException);

/// <summary>trnrund refused a request, such as a missing deck or an unknown simId; the daemon is still usable.</summary>
/// <param name="message">trnrund's error message.</param>
public sealed class RequestException(string message) : TRNRunException(message);

/// <summary>trnrund stopped answering: it crashed, or exited at startup, such as for an invalid option; the daemon is no longer usable.</summary>
/// <param name="message">Its exit code and what it wrote to stderr.</param>
public sealed class DaemonExitedException(string message) : TRNRunException(message);
