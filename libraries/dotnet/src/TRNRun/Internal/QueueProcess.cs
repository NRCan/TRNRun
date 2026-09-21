using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TRNRun.Interop;

namespace TRNRun.Internal;

/// <summary>Owns the queue process, its redirected pipes, and its Job Object.</summary>
/// <remarks>
/// The owner must stop sending, close input, drain stdout to EOF, wait, then dispose.
/// Waiting before EOF can deadlock on a full stdout pipe; disposing does not reap the queue.
/// </remarks>
internal sealed class QueueProcess : IDisposable
{
    private readonly Process _process;
    private readonly StreamWriter _stdin;
    private readonly StreamReader _stdout;
    private readonly WindowsJobObject? _job;

    /// <summary>Starts the queue with redirected UTF-8 pipes and best-effort Job Object protection.</summary>
    internal QueueProcess(string executable, int maxConcurrent)
    {
        // Omit the stdin BOM and replace malformed UTF-8 output.
        // Leave stderr inherited to avoid an undrained pipe.
        var utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        var startInfo = new ProcessStartInfo(executable)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            StandardInputEncoding = utf8NoBom,
            StandardOutputEncoding = utf8NoBom,
        };
        startInfo.ArgumentList.Add($"--maxConcurrent:{maxConcurrent}");

        _process = Process.Start(startInfo)
            ?? throw new InvalidOperationException("TRNRun queue did not start.");
        _stdin = _process.StandardInput;
        _stdout = _process.StandardOutput;

        _stdin.NewLine = "\n";
        _stdin.AutoFlush = true;
        _job = WindowsJobObject.TryAssign(_process);
    }

    /// <summary>Writes and flushes one request as a JSON line to queue stdin.</summary>
    internal void Send(QueueRequest request) =>
        _stdin.WriteLine(JsonSerializer.Serialize(request, QueueJsonContext.Default.QueueRequest));

    /// <summary>Reads the next stdout line, or returns null at EOF.</summary>
    internal string? ReadLine() => _stdout.ReadLine();

    /// <summary>Closes stdin so the queue finishes accepted work and exits.</summary>
    internal void CloseInput()
    {
        try
        {
            _stdin.Dispose();
        }
        catch (IOException)
        {
            // A queue that exited early leaves stdin broken; its output must still be drained.
        }
    }

    /// <summary>Waits for the drained queue to exit and returns its exit code.</summary>
    internal int WaitForExit()
    {
        _process.WaitForExit();
        return _process.ExitCode;
    }

    /// <summary>Terminates the process tree and reaps the queue when stdout cannot be drained.</summary>
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

    /// <summary>Releases pipes, the process handle, and the Job Object without waiting for exit.</summary>
    public void Dispose()
    {
        CloseInput();
        _stdout.Dispose();
        _process.Dispose();
        // Closing the job kills any remaining descendants.
        _job?.Dispose();
    }
}
