using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using System.Text.Json;
using TRNRun.Interop;

namespace TRNRun.Internal;

/// <summary>Owns the queue process, its redirected pipes, and its Job Object.</summary>
/// <remarks>
/// A background thread continuously drains stdout and owns its disposal. Callbacks run on that
/// thread, can run before construction returns, and must return promptly without waiting for the owner.
/// The owner must coordinate Shutdown and Dispose; they must not be concurrent or reentrant.
/// Callbacks must not call Shutdown or Dispose.
/// </remarks>
internal sealed class QueueProcess : IDisposable
{
    private const int ShutdownTimeoutMilliseconds = 5000;

    private readonly Process _process;
    private readonly StreamWriter _stdin;
    private readonly StreamReader _stdout;
    private readonly WindowsJobObject? _job;
    private readonly Thread _reader;
    private readonly Action<string> _onOutput;
    private readonly Action<Exception?> _onExit;
    private readonly object _writeLock = new();
    private int _closing;
    private int _shutdownActive;
    private bool _inputDisposed;
    private bool _disposed;

    /// <summary>Starts the queue with redirected UTF-8 pipes and best-effort Job Object protection.</summary>
    /// <param name="executable">Unquoted path to an existing queue executable.</param>
    /// <param name="maxConcurrent">Positive maximum number of concurrent workers.</param>
    /// <param name="onOutput">Receives each stdout line on the background reader thread.</param>
    /// <param name="onExit">Receives the first reader or output callback error, or null at normal EOF.</param>
    /// <remarks>
    /// Both callbacks may run before this constructor returns and must return promptly.
    /// onExit reports reader completion, not the process exit code. Exceptions from onExit are contained.
    /// </remarks>
    internal QueueProcess(
        string executable, int maxConcurrent, Action<string> onOutput, Action<Exception?> onExit)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(executable);
        ArgumentOutOfRangeException.ThrowIfLessThan(maxConcurrent, 1);
        ArgumentNullException.ThrowIfNull(onOutput);
        ArgumentNullException.ThrowIfNull(onExit);

        string fullPath = Path.GetFullPath(executable);
        if (!File.Exists(fullPath))
        {
            throw new FileNotFoundException($"Queue executable not found: '{fullPath}'.", fullPath);
        }

        _onOutput = onOutput;
        _onExit = onExit;

        // Omit the stdin BOM and replace malformed UTF-8 output.
        // Leave stderr inherited to avoid an undrained pipe.
        var utf8NoBom = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        var startInfo = new ProcessStartInfo(fullPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            StandardInputEncoding = utf8NoBom,
            StandardOutputEncoding = utf8NoBom,
        };
        startInfo.ArgumentList.Add($"--maxConcurrent:{maxConcurrent}");

        var process = new Process { StartInfo = startInfo };
        StreamWriter? stdin = null;
        StreamReader? stdout = null;
        WindowsJobObject? job = null;
        try
        {
            if (!process.Start())
            {
                throw new InvalidOperationException("TRNRun queue did not start.");
            }

            stdin = process.StandardInput;
            stdout = process.StandardOutput;
            stdin.NewLine = "\n";
            stdin.AutoFlush = true;
            job = WindowsJobObject.TryAssign(process);

            _process = process;
            _stdin = stdin;
            _stdout = stdout;
            _job = job;
            _reader = new Thread(ReadOutput)
            {
                IsBackground = true,
                Name = "TRNRun queue stdout",
            };
            // Publish all reader-visible fields before callbacks can run.
            _reader.Start();
        }
        catch
        {
            // No reader owns stdout until Start succeeds. Preserve the original startup error.
            KillQueue(process, job);
            try
            {
                process.WaitForExit(ShutdownTimeoutMilliseconds);
            }
            catch (Exception error) when (error is InvalidOperationException or Win32Exception)
            {
            }

            DisposeAfterFailedStart(stdin);
            DisposeAfterFailedStart(stdout);
            DisposeAfterFailedStart(process);
            throw;
        }
    }

    /// <summary>Serializes, writes, and flushes one request as a JSON line to queue stdin.</summary>
    /// <remarks>Concurrent sends are serialized. Sends after shutdown starts or reader completion are rejected.</remarks>
    internal void Send(QueueRequest request)
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _closing) != 0, this);
        string line = JsonSerializer.Serialize(request, QueueJsonContext.Default.QueueRequest);
        lock (_writeLock)
        {
            ObjectDisposedException.ThrowIf(Volatile.Read(ref _closing) != 0, this);
            _stdin.WriteLine(line);
        }
    }

    /// <summary>Kills and reaps the queue, closes input, and joins the stdout reader before releasing resources.</summary>
    /// <remarks>
    /// Descendant termination is best effort through the process tree and Job Object.
    /// Blocking waits share a five-second budget. Incomplete cleanup retains resources for a later retry.
    /// The owner must prevent concurrent or reentrant shutdown. Callbacks must not call Shutdown or Dispose.
    /// </remarks>
    /// <exception cref="TimeoutException">Cleanup did not complete within the wait budget; call again to retry.</exception>
    /// <exception cref="InvalidOperationException">Called from the reader thread, or another Shutdown or Dispose call is already active.</exception>
    internal void Shutdown()
    {
        if (Thread.CurrentThread == _reader)
        {
            throw new InvalidOperationException("Queue shutdown is not allowed from queue callbacks.");
        }

        if (Interlocked.CompareExchange(ref _shutdownActive, 1, 0) != 0)
        {
            throw new InvalidOperationException("Queue shutdown must not be concurrent or reentrant.");
        }

        try
        {
            if (_disposed)
            {
                return;
            }

            Interlocked.Exchange(ref _closing, 1);
            var deadline = Stopwatch.StartNew();

            // A sender may be blocked on a full pipe while holding _writeLock.
            // Kill before taking that lock, and retain the process if it cannot be reaped.
            KillQueue(_process, _job);
            if (!_process.WaitForExit(RemainingMilliseconds(deadline)))
            {
                throw new TimeoutException("TRNRun queue did not exit within five seconds. Retry Shutdown to finish cleanup.");
            }

            if (!_inputDisposed)
            {
                if (!Monitor.TryEnter(_writeLock, RemainingMilliseconds(deadline)))
                {
                    throw new TimeoutException("TRNRun queue input is still in use. Retry Shutdown to finish cleanup.");
                }

                try
                {
                    // Closing the pipe first prevents disposal from flushing buffered data to surviving descendants.
                    _stdin.BaseStream.Dispose();
                    try
                    {
                        _stdin.Dispose();
                    }
                    catch (Exception error) when (error is IOException or ObjectDisposedException)
                    {
                        // Flushing an already closed pipe is expected during forced shutdown.
                    }

                    _inputDisposed = true;
                }
                finally
                {
                    Monitor.Exit(_writeLock);
                }
            }

            if (!_reader.Join(RemainingMilliseconds(deadline)))
            {
                throw new TimeoutException("TRNRun queue reader is still running. Retry Shutdown to finish cleanup.");
            }

            // Process.Dispose also disposes redirected streams, so it must follow reader termination.
            _process.Dispose();
            _disposed = true;
        }
        finally
        {
            Volatile.Write(ref _shutdownActive, 0);
        }
    }

    /// <summary>Performs the same bounded, retryable cleanup as Shutdown.</summary>
    public void Dispose() => Shutdown();

    private void ReadOutput()
    {
        Exception? error = null;
        try
        {
            while (_stdout.ReadLine() is { } line)
            {
                _onOutput(line);
            }
        }
        catch (Exception readError)
        {
            error = readError;
        }
        finally
        {
            Interlocked.Exchange(ref _closing, 1);
            try
            {
                _stdout.Dispose();
            }
            catch (Exception disposeError)
            {
                error ??= disposeError;
            }

            try
            {
                _onExit(error);
            }
            catch (Exception)
            {
                // A terminal callback cannot report its own failure or terminate the host process.
            }
        }
    }

    private static int RemainingMilliseconds(Stopwatch deadline) =>
        (int)Math.Max(0, ShutdownTimeoutMilliseconds - deadline.ElapsedMilliseconds);

    private static void KillQueue(Process process, WindowsJobObject? job)
    {
        try
        {
            process.Kill(entireProcessTree: true);
        }
        catch (Exception error) when (error is Win32Exception or InvalidOperationException
            or NotSupportedException or AggregateException)
        {
            try
            {
                // Tree enumeration or descendant termination can fail while the queue is still alive.
                process.Kill();
            }
            catch (Exception killError) when (killError is Win32Exception or InvalidOperationException)
            {
                // The queue may already have exited, or termination may require a later retry.
            }
        }
        finally
        {
            // Closing the job also kills descendants after the queue itself has exited.
            job?.Dispose();
        }
    }

    private static void DisposeAfterFailedStart(IDisposable? resource)
    {
        try
        {
            if (resource is StreamWriter writer)
            {
                writer.BaseStream.Dispose();
            }

            resource?.Dispose();
        }
        catch (Exception)
        {
            // Startup cleanup must not replace the original launch or thread-start failure.
        }
    }
}
