using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using TRNRun.Interop;

namespace TRNRun.Internal;

/// <summary>Owns the queue process, its redirected pipes, and its Job Object.</summary>
/// <remarks>
/// This type carries transport and framing only; it neither builds requests nor interprets
/// queue output. The manager must drain stdout to EOF before calling <see cref="WaitForExit"/>,
/// because a queue blocked on a full stdout pipe never exits.
/// </remarks>
internal sealed class QueueProcess : IDisposable
{
    private static readonly UTF8Encoding Utf8NoBom = new(encoderShouldEmitUTF8Identifier: false);

    private readonly Process _process;
    private readonly WindowsJobObject? _job;
    private bool _inputClosed;
    private bool _disposed;

    /// <summary>Starts the queue executable with redirected stdin and stdout.</summary>
    /// <param name="executable">Full path to an existing queue executable.</param>
    /// <param name="maxConcurrent">Positive worker count passed to the queue.</param>
    /// <remarks>A failed start releases the pipes and the process handle before rethrowing.</remarks>
    /// <exception cref="InvalidOperationException">The queue process did not start.</exception>
    /// <exception cref="System.ComponentModel.Win32Exception">The executable could not be launched.</exception>
    internal QueueProcess(string executable, int maxConcurrent)
    {
        _process = new Process { StartInfo = CreateStartInfo(executable, maxConcurrent) };

        try
        {
            if (!_process.Start())
            {
                throw new InvalidOperationException("TRNRun queue did not start.");
            }

            // The native queue reads newline-delimited requests and must never receive CRLF.
            _process.StandardInput.NewLine = "\n";
            _job = WindowsJobObject.TryAssign(_process);
        }
        catch
        {
            // No submissions exist yet, so closing stdin is enough to stop a queue that did
            // start. Releasing pipes the process never opened is a no-op.
            Dispose();
            throw;
        }
    }

    /// <summary>Encodes one request as JSON and writes it to queue stdin as a single line.</summary>
    /// <param name="request">The request to submit.</param>
    /// <remarks>A failed write is not retried: the queue may already have read the request.</remarks>
    /// <exception cref="IOException">The request could not be written or flushed.</exception>
    internal void Send(QueueRequest request)
    {
        Debug.Assert(!_inputClosed, "Requests cannot be sent after queue input is closed.");

        string line = JsonSerializer.Serialize(request, QueueJsonContext.Default.QueueRequest);

        StreamWriter input = _process.StandardInput;
        input.WriteLine(line);
        input.Flush();
    }

    /// <summary>Reads one line of queue stdout, or null at EOF.</summary>
    internal string? ReadLine() => _process.StandardOutput.ReadLine();

    /// <summary>Closes queue stdin so the queue stops accepting work and exits once drained.</summary>
    /// <remarks>Repeated calls do nothing.</remarks>
    internal void CloseInput()
    {
        if (_inputClosed)
        {
            return;
        }

        _inputClosed = true;

        // A queue that exited early may have broken stdin; still drain its output and reap it.
        Quietly(() => _process.StandardInput.Dispose());
    }

    /// <summary>Waits for the queue to exit and returns its exit code.</summary>
    /// <remarks>Call only after stdout reaches EOF; waiting earlier can deadlock on a full pipe.</remarks>
    internal int WaitForExit()
    {
        _process.WaitForExit();
        return _process.ExitCode;
    }

    /// <summary>Terminates the queue process tree and reaps it.</summary>
    /// <remarks>Used only when stdout cannot be drained, never for normal shutdown or a run's failure.</remarks>
    /// <exception cref="AggregateException">Part of the process tree could not be terminated.</exception>
    /// <exception cref="System.ComponentModel.Win32Exception">The queue process could not be terminated.</exception>
    internal void Abort()
    {
        try
        {
            _process.Kill(entireProcessTree: true);
        }
        catch (InvalidOperationException) when (_process.HasExited)
        {
            // The queue may have exited between the read failure and emergency cleanup.
        }

        _process.WaitForExit();
    }

    /// <summary>Releases the pipes, the process handle, and the Job Object.</summary>
    /// <remarks>
    /// <para>
    /// Disposal releases resources only: it neither drains the queue nor waits for it, so the
    /// owner must still drain stdout and reap the process first. Closing the Job Object handle
    /// terminates anything left running in it.
    /// </para>
    /// <para>
    /// Every step runs even when an earlier one fails, and cleanup failures are swallowed,
    /// because this runs from the owner's finally block where throwing would mask the real
    /// error. Repeated calls do nothing. No finalizer is needed: <see cref="Process"/> and the
    /// Job Object handle release themselves if this is never called.
    /// </para>
    /// </remarks>
    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        CloseInput();
        Quietly(() => _process.StandardOutput.Dispose());
        Quietly(_process.Dispose);
        _job?.Dispose();
    }

    /// <summary>Builds the start info for a queue process with redirected pipes.</summary>
    /// <remarks>
    /// Stderr is inherited so native diagnostics reach the host console instead of filling a
    /// second pipe that nobody drains. Invalid UTF-8 decodes to U+FFFD rather than throwing,
    /// so a garbled line is dropped by the parser instead of ending the drain.
    /// </remarks>
    private static ProcessStartInfo CreateStartInfo(string executable, int maxConcurrent)
    {
        var startInfo = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = false,
            StandardInputEncoding = Utf8NoBom,
            StandardOutputEncoding = Utf8NoBom,
        };

        startInfo.ArgumentList.Add(
            "--maxConcurrent:" + maxConcurrent.ToString(CultureInfo.InvariantCulture));

        return startInfo;
    }

    /// <summary>Runs one cleanup step, ignoring the failures cleanup can legitimately hit.</summary>
    /// <remarks>
    /// A pipe that is broken, already released, or never opened leaves nothing left to release.
    /// </remarks>
    private static void Quietly(Action cleanup)
    {
        try
        {
            cleanup();
        }
        catch (Exception error)
            when (error is IOException or ObjectDisposedException or InvalidOperationException)
        {
        }
    }
}
