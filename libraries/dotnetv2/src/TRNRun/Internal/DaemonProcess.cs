using System.Buffers;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using TRNRun.Interop;

namespace TRNRun.Internal;

/// <summary>A running trnrund, read by a background thread.</summary>
/// <remarks>
/// The thread sorts each stdout line: replies go to the waiting request, matched by <c>id</c>,
/// and <c>changed</c> notifications wake <see cref="WaitForChange"/>. trnrund's stdout ends
/// only after its final changes are saved, so the end of stdout is how a crashed daemon is
/// noticed. stderr is captured rather than shown: trnrund writes to it only before a fatal
/// exit, and that text is added to the <see cref="DaemonException"/> reporting the exit.
/// Requests are serialized, so any thread may send one.
/// </remarks>
internal sealed class DaemonProcess : IDisposable
{
    /// <summary>How long to wait for trnrund to exit once its stdout ended.</summary>
    private static readonly TimeSpan ExitWait = TimeSpan.FromSeconds(10);

    /// <summary>How long trnrund gets, by default, to save interrupted runs and exit once stdin is closed.</summary>
    internal static readonly TimeSpan DefaultCloseWait = TimeSpan.FromSeconds(10);

    /// <summary>Keeps non-ASCII text, such as accented deck paths, as UTF-8 instead of escaping it.</summary>
    private static readonly JsonWriterOptions WriterOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private readonly Process _process;
    private readonly StreamWriter _stdin;
    private readonly Thread _reader;
    private readonly TimeSpan _requestTimeout;
    private readonly TimeSpan _closeWait;
    // Serializes requests, so replies arrive in the order they are awaited.
    private readonly Lock _requestLock = new();
    private long _nextId;
    // Replies read from stdout; completed once stdout ends.
    private readonly BlockingCollection<JsonElement> _replies = [];
    // Guards _revision and _ended; pulsed when either changes.
    private readonly object _changed = new();
    private long _revision;
    private bool _ended;
    // Set once the caller ends the process, so its exit is not an error.
    private volatile bool _expectExit;
    // Guards _diagnostics, read once from stderr, and _closed.
    private readonly Lock _exitLock = new();
    private string? _diagnostics;
    private volatile bool _closed;

    /// <summary>Starts trnrund with <paramref name="args"/> without a console window, in the kill-on-close job; does not wait for it.</summary>
    /// <param name="trnrundPath">trnrund executable.</param>
    /// <param name="args">Unquoted command-line arguments.</param>
    /// <param name="requestTimeout">How long a request waits for its reply by default.</param>
    /// <param name="closeWait">How long <see cref="Close"/> lets trnrund exit before killing it.</param>
    /// <exception cref="FileNotFoundException">The executable does not exist.</exception>
    internal DaemonProcess(string trnrundPath, IEnumerable<string> args, TimeSpan requestTimeout, TimeSpan? closeWait = null)
    {
        _requestTimeout = requestTimeout;
        _closeWait = closeWait ?? DefaultCloseWait;
        var utf8 = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);
        var startInfo = new ProcessStartInfo(trnrundPath)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardInputEncoding = utf8,
            StandardOutputEncoding = utf8,
            StandardErrorEncoding = utf8,
        };
        foreach (string arg in args)
        {
            startInfo.ArgumentList.Add(arg);
        }

        try
        {
            _process = Process.Start(startInfo)!;
        }
        catch (Win32Exception error) when (error.NativeErrorCode is 2 or 3)
        {
            const string hint = "Run 'just trnrund-bin' from the repository root and rebuild, or pass trnrundPath.";
            throw new FileNotFoundException($"trnrund executable not found: {trnrundPath}. {hint}", trnrundPath, error);
        }

        _ = WindowsJob.TryAssign(_process);
        _stdin = _process.StandardInput;
        _stdin.NewLine = "\n";
        _reader = new Thread(Read) { IsBackground = true, Name = "trnrund-stdout" };
        _reader.Start();
    }

    /// <summary>trnrund's process ID.</summary>
    internal int ProcessId => _process.Id;

    /// <summary>trnrund's exit code once <see cref="Close"/> has reaped it, else <see langword="null"/>.</summary>
    internal int? ExitCode { get; private set; }

    // -----------------------------------------------------------------
    // Reading stdout
    // -----------------------------------------------------------------

    /// <summary>Dispatches every stdout line until it ends, then wakes every waiter.</summary>
    private void Read()
    {
        try
        {
            while (_process.StandardOutput.ReadLine() is { } line)
            {
                Dispatch(line);
            }
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException)
        {
            // Closed by Close(); the daemon is ending either way.
        }
        finally
        {
            lock (_changed)
            {
                _ended = true;
                Monitor.PulseAll(_changed);
            }

            _replies.CompleteAdding();
        }
    }

    /// <summary>Routes one stdout line to its request or to change waiters; other lines are ignored.</summary>
    private void Dispatch(string line)
    {
        JsonElement message;
        try
        {
            using JsonDocument document = JsonDocument.Parse(line);
            message = document.RootElement.Clone();
        }
        catch (JsonException)
        {
            return;
        }

        if (message.ValueKind != JsonValueKind.Object)
        {
            return;
        }

        if (message.TryGetProperty("event", out JsonElement kind))
        {
            if (kind.ValueKind == JsonValueKind.String && kind.ValueEquals("changed")
                && TryGetInt64(message, "revision", out long revision))
            {
                lock (_changed)
                {
                    _revision = Math.Max(_revision, revision);
                    Monitor.PulseAll(_changed);
                }
            }
        }
        else if (message.TryGetProperty("ok", out JsonElement ok) && ok.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            _replies.Add(message);
        }
    }

    // -----------------------------------------------------------------
    // Requests and notifications
    // -----------------------------------------------------------------

    /// <summary>Sends one request and returns its reply.</summary>
    /// <param name="cmd">The request's <c>cmd</c>.</param>
    /// <param name="writeFields">Writes the request's other fields, if any.</param>
    /// <param name="timeout">How long to wait for the reply; by default the instance's request timeout.</param>
    /// <exception cref="ArgumentException">trnrund rejected the request.</exception>
    /// <exception cref="TimeoutException">No reply arrived within the timeout.</exception>
    /// <exception cref="DaemonException">trnrund has exited or is closed.</exception>
    internal JsonElement Request(string cmd, Action<Utf8JsonWriter>? writeFields = null, TimeSpan? timeout = null)
    {
        TimeSpan limit = timeout ?? _requestTimeout;
        JsonElement reply;
        lock (_requestLock)
        {
            if (_closed)
            {
                throw new DaemonException("trnrund is closed");
            }

            long requestId = ++_nextId;
            try
            {
                _stdin.WriteLine(Serialize(requestId, cmd, writeFields));
                _stdin.Flush();
            }
            catch (Exception exception) when (exception is IOException or ObjectDisposedException)
            {
                throw _closed ? new DaemonException("trnrund is closed") : CreateExitError();
            }

            var elapsed = Stopwatch.StartNew();
            while (true)
            {
                if (!_replies.TryTake(out reply, Remaining(limit, elapsed)))
                {
                    if (_replies.IsCompleted)
                    {
                        throw CreateExitError();
                    }

                    throw new TimeoutException(string.Create(
                        CultureInfo.InvariantCulture, $"trnrund did not answer '{cmd}' within {limit.TotalSeconds} s"));
                }

                if (TryGetInt64(reply, "id", out long id) && id == requestId)
                {
                    break;
                }

                // Otherwise it answers an earlier request that timed out.
            }
        }

        if (reply.GetProperty("ok").ValueKind != JsonValueKind.True)
        {
            throw new ArgumentException(
                reply.TryGetProperty("error", out JsonElement error) && error.ValueKind == JsonValueKind.String
                    ? error.GetString()
                    : "trnrund rejected the request");
        }

        return reply;
    }

    /// <summary>Blocks until trnrund announces a revision after <paramref name="afterRevision"/>, or its stdout ends.</summary>
    /// <returns>False if <paramref name="timeout"/> passes first; <see langword="null"/> waits indefinitely.</returns>
    /// <remarks>Safe from any thread.</remarks>
    internal bool WaitForChange(long afterRevision, TimeSpan? timeout = null)
    {
        TimeSpan limit = timeout ?? Timeout.InfiniteTimeSpan;
        var elapsed = Stopwatch.StartNew();
        lock (_changed)
        {
            while (_revision <= afterRevision && !_ended)
            {
                TimeSpan remaining = Remaining(limit, elapsed);
                if (remaining == TimeSpan.Zero)
                {
                    return false;
                }

                _ = Monitor.Wait(_changed, remaining);
            }

            return true;
        }
    }

    // -----------------------------------------------------------------
    // Exit
    // -----------------------------------------------------------------

    /// <summary>Returns how trnrund exited if it ended before <see cref="Wait"/> or <see cref="Close"/>, else <see langword="null"/>.</summary>
    /// <remarks>Its stdout ends only after its final changes are saved, so everything it saved is readable once this returns an error.</remarks>
    internal DaemonException? GetExitError()
    {
        bool ended;
        lock (_changed)
        {
            ended = _ended;
        }

        return ended && !_expectExit ? CreateExitError() : null;
    }

    /// <summary>Waits for trnrund to exit by itself, as after <c>shutdown</c>, then closes it.</summary>
    /// <returns>False, leaving it running, if <paramref name="timeout"/> passes first; <see langword="null"/> waits indefinitely.</returns>
    /// <exception cref="DaemonException">It exited with an error, reported with its diagnostics.</exception>
    internal bool Wait(TimeSpan? timeout = null)
    {
        _expectExit = true;
        if (!_process.WaitForExit(timeout ?? Timeout.InfiniteTimeSpan))
        {
            return false;
        }

        DaemonException? error = _process.ExitCode != 0 ? CreateExitError() : null;
        Close();
        if (error is not null)
        {
            throw error;
        }

        return true;
    }

    /// <summary>Closes stdin, which interrupts unfinished runs, and waits for trnrund to exit.</summary>
    /// <remarks>
    /// A trnrund still running after the close wait is killed, and its job object kills its runs
    /// with it, so closing never hangs. Safe to call again, after <see cref="Wait"/>, or after
    /// trnrund crashed.
    /// </remarks>
    internal void Close()
    {
        _expectExit = true;
        lock (_exitLock)
        {
            if (_closed)
            {
                return;
            }

            _closed = true;
        }

        try
        {
            // Closing the pipe first keeps a failed flush, after a crash, from leaving it open.
            _stdin.BaseStream.Dispose();
            _stdin.Dispose();
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException)
        {
        }

        if (!_process.WaitForExit(_closeWait))
        {
            try
            {
                _process.Kill(entireProcessTree: true);
            }
            catch (Exception error) when (error is Win32Exception or InvalidOperationException or AggregateException)
            {
                // It exited meanwhile.
            }

            _process.WaitForExit();
        }

        ExitCode = _process.ExitCode;
        if (Thread.CurrentThread != _reader && !_reader.Join(ExitWait))
        {
            // Its blocked read would make disposing stdout hang too; the background thread is left.
            return;
        }

        _process.Dispose();
    }

    /// <summary>Same as <see cref="Close"/>.</summary>
    public void Dispose() => Close();

    /// <summary>Describes how trnrund exited, waiting briefly for it if needed.</summary>
    private DaemonException CreateExitError()
    {
        try
        {
            if (!_process.WaitForExit(ExitWait))
            {
                return new DaemonException("trnrund closed its output but did not exit");
            }

            int code = _process.ExitCode;
            string diagnostics;
            lock (_exitLock)
            {
                _diagnostics ??= ReadDiagnostics();
                diagnostics = _diagnostics;
            }

            string message = string.Create(CultureInfo.InvariantCulture, $"trnrund exited with code {code}");
            return new DaemonException(diagnostics.Length > 0 ? $"{message}: {diagnostics}" : message, code, diagnostics);
        }
        catch (InvalidOperationException)
        {
            return new DaemonException("trnrund is closed"); // Disposed by a concurrent Close().
        }
    }

    /// <summary>Reads what trnrund wrote to stderr; empty if it cannot be read.</summary>
    private string ReadDiagnostics()
    {
        try
        {
            return _process.StandardError.ReadToEnd().Trim();
        }
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException)
        {
            return "";
        }
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// <summary>Serializes one request line: its <c>id</c> and <c>cmd</c> first, then its other fields.</summary>
    private static string Serialize(long id, string cmd, Action<Utf8JsonWriter>? writeFields)
    {
        var buffer = new ArrayBufferWriter<byte>();
        using (var writer = new Utf8JsonWriter(buffer, WriterOptions))
        {
            writer.WriteStartObject();
            writer.WriteNumber("id", id);
            writer.WriteString("cmd", cmd);
            writeFields?.Invoke(writer);
            writer.WriteEndObject();
        }

        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    /// <summary>Reads an integer property, false if it is missing or not an integer.</summary>
    internal static bool TryGetInt64(JsonElement message, string name, out long value)
    {
        value = 0;
        return message.TryGetProperty(name, out JsonElement element)
            && element.ValueKind == JsonValueKind.Number
            && element.TryGetInt64(out value);
    }

    /// <summary>Returns what is left of <paramref name="limit"/>, never negative; an infinite limit stays infinite.</summary>
    private static TimeSpan Remaining(TimeSpan limit, Stopwatch elapsed)
    {
        if (limit == Timeout.InfiniteTimeSpan)
        {
            return limit;
        }

        TimeSpan remaining = limit - elapsed.Elapsed;
        return remaining > TimeSpan.Zero ? remaining : TimeSpan.Zero;
    }
}
