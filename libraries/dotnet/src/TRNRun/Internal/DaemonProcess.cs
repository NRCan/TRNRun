using System.Buffers;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Threading.Channels;

namespace TRNRun.Internal;

/// <summary>A running trnrund, whose stdout a background thread routes to requests and change waiters.</summary>
/// <remarks>
/// stdout ends only after trnrund's final saves, so its end is how an exit is noticed; the exit is
/// recorded, with stderr, before waiters wake. Every await resumes on the thread pool, so the
/// blocking members, built on the async ones, never deadlock on a caller's context.
/// </remarks>
internal sealed class DaemonProcess : IDisposable, IAsyncDisposable
{
    /// <summary>How long to wait for trnrund to exit once its stdout ended.</summary>
    private static readonly TimeSpan ExitWait = TimeSpan.FromSeconds(10);

    /// <summary>How long trnrund gets, by default, to exit once stdin is closed.</summary>
    internal static readonly TimeSpan DefaultCloseWait = TimeSpan.FromSeconds(10);

    /// <summary>Keeps non-ASCII text, such as accented deck paths, unescaped.</summary>
    private static readonly JsonWriterOptions WriterOptions = new() { Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping };

    private readonly Process _process;
    private readonly StreamWriter _stdin;
    private readonly TimeSpan _requestTimeout;
    private readonly TimeSpan _closeWait;
    private readonly TaskCompletionSource _readerDone = new(TaskCreationOptions.RunContinuationsAsynchronously);
    // One request at a time, so replies arrive in the order they are awaited.
    private readonly SemaphoreSlim _requestLock = new(1, 1);
    private long _nextId;
    private readonly Channel<JsonElement> _replies =
        Channel.CreateUnbounded<JsonElement>(new UnboundedChannelOptions { SingleReader = true, SingleWriter = true });
    // Guards the fields below; pulsed, and _signal completed, on any change.
    private readonly object _changed = new();
    private TaskCompletionSource _signal = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private long _revision;
    private bool _ended;
    // Null if trnrund closed stdout without exiting.
    private int? _exitCode;
    private string _diagnostics = "";
    // Set once the caller ends the process, so its exit is not an error.
    private Task? _closing;

    /// <summary>Starts trnrund without a console window or waiting for it; throws <see cref="FileNotFoundException"/> if missing.</summary>
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
            const string hint = "Run 'just trnrund-bin' from the repository root and rebuild, or set DaemonOptions.TrnrundPath.";
            throw new FileNotFoundException($"trnrund executable not found: {trnrundPath}. {hint}", trnrundPath, error);
        }

        _stdin = _process.StandardInput;
        _stdin.NewLine = "\n";
        // A dedicated thread: stdout is a synchronous pipe, so an async read would hold a pool thread anyway.
        new Thread(Read) { IsBackground = true, Name = "trnrund-stdout" }.Start();
    }

    /// <summary>trnrund's process ID.</summary>
    internal int ProcessId => _process.Id;

    /// <summary>trnrund's exit code once <see cref="Close"/> has reaped it, else <see langword="null"/>.</summary>
    internal int? ExitCode { get; private set; }

    /// <summary>Dispatches every stdout line until it ends, records the exit, then wakes every waiter.</summary>
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
            // stderr is read only once trnrund exited.
            int? exitCode = null;
            string diagnostics = "";
            try
            {
                if (_process.WaitForExit(ExitWait))
                {
                    exitCode = _process.ExitCode;
                    diagnostics = _process.StandardError.ReadToEnd().Trim();
                }
            }
            catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException)
            {
            }

            Signal(() => (_exitCode, _diagnostics, _ended) = (exitCode, diagnostics, true));
            _replies.Writer.TryComplete();
            _readerDone.TrySetResult();
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
                Signal(() => _revision = Math.Max(_revision, revision));
            }
        }
        else if (message.TryGetProperty("ok", out JsonElement ok) && ok.ValueKind is JsonValueKind.True or JsonValueKind.False)
        {
            _replies.Writer.TryWrite(message);
        }
    }

    /// <summary>Applies <paramref name="change"/> under the lock, then wakes every change waiter.</summary>
    private void Signal(Action change)
    {
        TaskCompletionSource signal;
        lock (_changed)
        {
            change();
            (signal, _signal) = (_signal, new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously));
            Monitor.PulseAll(_changed);
        }

        signal.TrySetResult();
    }

    /// <summary>Blocking version of <see cref="RequestAsync"/>.</summary>
    internal JsonElement Request(string cmd, Action<Utf8JsonWriter>? writeFields = null, TimeSpan? timeout = null) =>
        RequestAsync(cmd, writeFields, timeout, CancellationToken.None).GetAwaiter().GetResult();

    /// <summary>Sends one request and returns its reply, or throws <see cref="RequestRejectedException"/> or <see cref="TimeoutException"/>.</summary>
    /// <remarks>A timed-out or cancelled request is abandoned, though trnrund may still carry it out; its late reply is skipped.</remarks>
    internal async Task<JsonElement> RequestAsync(
        string cmd, Action<Utf8JsonWriter>? writeFields, TimeSpan? timeout, CancellationToken cancellationToken)
    {
        TimeSpan limit = timeout ?? _requestTimeout;
        JsonElement reply;
        await _requestLock.WaitAsync(cancellationToken).ConfigureAwait(false);
        try
        {
            if (Volatile.Read(ref _closing) is not null)
            {
                throw new DaemonClosedException("trnrund is closed");
            }

            long requestId = ++_nextId;
            try
            {
                // Never cancelled: half a line would corrupt every later request.
                await _stdin.WriteLineAsync(Serialize(requestId, cmd, writeFields)).ConfigureAwait(false);
                await _stdin.FlushAsync(CancellationToken.None).ConfigureAwait(false);
            }
            catch (Exception error) when (error is IOException or ObjectDisposedException)
            {
                // trnrund ended or Close() closed stdin; the reply loop reports which.
            }

            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(limit);
            while (true)
            {
                try
                {
                    reply = await _replies.Reader.ReadAsync(deadline.Token).ConfigureAwait(false);
                }
                catch (ChannelClosedException)
                {
                    throw ExitError();
                }
                catch (OperationCanceledException) when (!cancellationToken.IsCancellationRequested)
                {
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
        finally
        {
            _requestLock.Release();
        }

        if (reply.GetProperty("ok").ValueKind != JsonValueKind.True)
        {
            throw new RequestRejectedException(
                reply.TryGetProperty("error", out JsonElement error) && error.ValueKind == JsonValueKind.String
                    ? error.GetString()!
                    : "trnrund rejected the request");
        }

        return reply;
    }

    /// <summary>Blocks until trnrund announces a revision after <paramref name="afterRevision"/>, false on timeout; throws once it ended with nothing newer.</summary>
    internal bool WaitForChanges(long afterRevision, TimeSpan timeout)
    {
        var elapsed = Stopwatch.StartNew();
        lock (_changed)
        {
            while (_revision <= afterRevision && !_ended)
            {
                TimeSpan remaining = Remaining(timeout, elapsed);
                if (remaining == TimeSpan.Zero)
                {
                    return false;
                }

                _ = Monitor.Wait(_changed, remaining);
            }

            if (_revision > afterRevision)
            {
                return true;
            }
        }

        throw ExitError();
    }

    /// <summary>Async version of <see cref="WaitForChanges"/>, without the timeout.</summary>
    internal async Task WaitForChangesAsync(long afterRevision, CancellationToken cancellationToken)
    {
        while (true)
        {
            Task signal;
            lock (_changed)
            {
                if (_revision > afterRevision)
                {
                    return;
                }

                if (_ended)
                {
                    break;
                }

                signal = _signal.Task;
            }

            await signal.WaitAsync(cancellationToken).ConfigureAwait(false);
        }

        throw ExitError();
    }

    /// <summary>Waits for trnrund to exit by itself, as after <c>shutdown</c>, then closes it; false, leaving it running, on timeout.</summary>
    internal bool Wait(TimeSpan timeout)
    {
        if (!_process.WaitForExit(timeout))
        {
            return false;
        }

        int code = _process.ExitCode;
        Close();
        ThrowIfFailed(code);
        return true;
    }

    /// <summary>Async version of <see cref="Wait"/>; cancelling leaves trnrund running.</summary>
    internal async Task WaitAsync(CancellationToken cancellationToken)
    {
        await _process.WaitForExitAsync(cancellationToken).ConfigureAwait(false);
        int code = _process.ExitCode;
        await CloseAsync().ConfigureAwait(false);
        ThrowIfFailed(code);
    }

    /// <summary>Throws <see cref="DaemonExitedException"/>, with stderr, unless <paramref name="code"/> is 0.</summary>
    private void ThrowIfFailed(int code)
    {
        if (code != 0)
        {
            string diagnostics;
            lock (_changed)
            {
                diagnostics = _diagnostics; // Recorded by the reader, which closing waited for.
            }

            throw new DaemonExitedException(code, diagnostics);
        }
    }

    /// <summary>Blocking version of <see cref="CloseAsync"/>.</summary>
    internal void Close() => CloseAsync().GetAwaiter().GetResult();

    /// <summary>Closes stdin, interrupting unfinished runs, and waits for trnrund to exit, killing it after the close wait.</summary>
    /// <remarks>Every call awaits the same closing, so it is safe to repeat, concurrently or after a crash.</remarks>
    internal Task CloseAsync()
    {
        lock (_changed)
        {
            return _closing ??= Task.Run(CloseCoreAsync);
        }
    }

    /// <summary>Closes the process once, for <see cref="CloseAsync"/>.</summary>
    private async Task CloseCoreAsync()
    {
        try
        {
            // Closing the pipe first keeps a failed flush, after a crash, from leaving it open.
            _stdin.BaseStream.Dispose();
            _stdin.Dispose();
        }
        // InvalidOperationException: a request's write is still in flight; the pipe is closed regardless.
        catch (Exception error) when (error is IOException or ObjectDisposedException or InvalidOperationException)
        {
        }

        using (var grace = new CancellationTokenSource(_closeWait))
        {
            try
            {
                await _process.WaitForExitAsync(grace.Token).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                try
                {
                    _process.Kill(entireProcessTree: true);
                }
                catch (Exception error) when (error is Win32Exception or InvalidOperationException or AggregateException)
                {
                    // It exited meanwhile.
                }

                await _process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
            }
        }

        ExitCode = _process.ExitCode;
        try
        {
            await _readerDone.Task.WaitAsync(ExitWait).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            // Its blocked read would make disposing stdout hang too; the background thread is left.
            return;
        }

        _process.Dispose();
    }

    /// <summary>Same as <see cref="Close"/>.</summary>
    public void Dispose() => Close();

    /// <summary>Same as <see cref="CloseAsync"/>.</summary>
    public ValueTask DisposeAsync() => new(CloseAsync());

    /// <summary>Returns why trnrund no longer answers.</summary>
    private TrnrunException ExitError()
    {
        lock (_changed)
        {
            return _exitCode == 0 || _closing is not null
                ? new DaemonClosedException("trnrund is closed")
                : new DaemonExitedException(_exitCode, _diagnostics);
        }
    }

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
