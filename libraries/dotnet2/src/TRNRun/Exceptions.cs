namespace TRNRun;

/// <summary>Base class of the exceptions this library throws.</summary>
/// <param name="message">What went wrong.</param>
public class TrnrunException(string message) : Exception(message);

/// <summary>trnrund refused a request, such as a missing deck or an unknown simId.</summary>
/// <param name="message">trnrund's error message.</param>
public sealed class RequestException(string message) : TrnrunException(message);

/// <summary>trnrund stopped answering: it crashed, or exited at startup, such as for an invalid option.</summary>
/// <param name="message">Its exit code and what it wrote to stderr.</param>
public sealed class DaemonExitedException(string message) : TrnrunException(message);
