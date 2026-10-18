using System.Globalization;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using TRNRun.Internal;

namespace TRNRun;

/// <summary>A running trnrund: submit runs, and wait until its database changes.</summary>
/// <remarks>
/// <para>
/// Start one with <see cref="Start"/> or <see cref="StartAsync"/>. trnrund saves every run and
/// log to SQLite; read it with <see cref="OpenDatabase"/> and
/// <see cref="TrnrunDatabase.ReadChanges"/> or plain SQL.
/// </para>
/// <para>
/// Every member is thread-safe, and each one that waits for trnrund has an asynchronous
/// version taking a <see cref="CancellationToken"/>. Disposing the daemon interrupts unfinished
/// runs; afterwards its members throw <see cref="ObjectDisposedException"/>.
/// </para>
/// </remarks>
public sealed class Daemon : IDisposable, IAsyncDisposable
{
    private readonly DaemonProcess _process;
    private readonly DirectoryInfo? _temporary;
    private volatile bool _disposed;

    /// <summary>Wraps a started trnrund from its <c>ready</c> reply.</summary>
    /// <exception cref="TrnrunException">The reply lacks a field.</exception>
    private Daemon(DaemonProcess process, DirectoryInfo? temporary, JsonElement ready)
    {
        _process = process;
        _temporary = temporary;
        DatabasePath = ReplyString(ready, "databasePath");
        SessionId = ReplyInt64(ready, "sessionId");
        StartPosition = new ChangePosition(ReplyInt64(ready, "revision"), ReplyInt64(ready, "logId"));
    }

    /// <summary>The database trnrund opened.</summary>
    public string DatabasePath { get; }

    /// <summary>This daemon's session, recorded on every run it adds.</summary>
    public long SessionId { get; }

    /// <summary>The latest revision and log ID when the daemon started; read after it to see only its changes.</summary>
    public ChangePosition StartPosition { get; }

    /// <summary>trnrund's process ID.</summary>
    internal int ProcessId => _process.ProcessId;

    // -----------------------------------------------------------------
    // Starting
    // -----------------------------------------------------------------

    /// <summary>Starts trnrund and waits until it is ready.</summary>
    /// <param name="options">How to start it; by default with a temporary database and the bundled executables.</param>
    /// <exception cref="FileNotFoundException">trnrund does not exist.</exception>
    /// <exception cref="DaemonExitedException">trnrund failed to start, with its message.</exception>
    /// <exception cref="TimeoutException">trnrund did not answer within <see cref="DaemonOptions.RequestTimeout"/>.</exception>
    public static Daemon Start(DaemonOptions? options = null)
    {
        (DaemonProcess process, DirectoryInfo? temporary) = Launch(options ?? new DaemonOptions());
        try
        {
            return new Daemon(process, temporary, process.Request("ready"));
        }
        catch
        {
            process.Close();
            DeleteTemporary(temporary);
            throw;
        }
    }

    /// <summary>Starts trnrund and waits until it is ready, without blocking.</summary>
    /// <param name="options">How to start it; by default with a temporary database and the bundled executables.</param>
    /// <param name="cancellationToken">Stops waiting, closes trnrund, and throws <see cref="OperationCanceledException"/>.</param>
    /// <exception cref="FileNotFoundException">trnrund does not exist.</exception>
    /// <exception cref="DaemonExitedException">trnrund failed to start, with its message.</exception>
    /// <exception cref="TimeoutException">trnrund did not answer within <see cref="DaemonOptions.RequestTimeout"/>.</exception>
    public static async Task<Daemon> StartAsync(DaemonOptions? options = null, CancellationToken cancellationToken = default)
    {
        (DaemonProcess process, DirectoryInfo? temporary) = Launch(options ?? new DaemonOptions());
        try
        {
            JsonElement ready = await process.RequestAsync("ready", null, null, cancellationToken).ConfigureAwait(false);
            return new Daemon(process, temporary, ready);
        }
        catch
        {
            await process.CloseAsync().ConfigureAwait(false);
            DeleteTemporary(temporary);
            throw;
        }
    }

    /// <summary>Starts the trnrund process for <paramref name="options"/>, with a temporary database directory if it names none.</summary>
    private static (DaemonProcess Process, DirectoryInfo? Temporary) Launch(DaemonOptions options)
    {
        DirectoryInfo? temporary = null;
        try
        {
            string databasePath = options.DatabasePath ?? Path.Combine(
                (temporary = Directory.CreateTempSubdirectory("trnrun-")).FullName, "runs.sqlite3");
            var args = new List<string>
            {
                $"--trnrun:{Path.GetFullPath(options.TrnrunPath)}",
                $"--database:{Path.GetFullPath(databasePath)}",
            };
            if (options.MaxConcurrent is { } slots)
            {
                args.Add(string.Create(CultureInfo.InvariantCulture, $"--maxConcurrent:{slots}"));
            }

            return (new DaemonProcess(options.TrnrundPath, args, options.RequestTimeout), temporary);
        }
        catch
        {
            DeleteTemporary(temporary);
            throw;
        }
    }

    // -----------------------------------------------------------------
    // Requests
    // -----------------------------------------------------------------

    /// <summary>Submits a deck and returns its run ID once saved, not finished.</summary>
    /// <param name="deckFile">Deck to run; a relative one resolves from the current working directory, not the daemon's.</param>
    /// <param name="trnrunArgs">Raw TRNRun options, such as <c>--watchTmp:true</c>.</param>
    /// <param name="label">Optional tag saved with the run.</param>
    /// <exception cref="RequestRejectedException">trnrund refused the run, with its reason.</exception>
    /// <exception cref="ClosedException">The daemon was shut down.</exception>
    /// <exception cref="DaemonExitedException">trnrund exited.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public long Add(string deckFile, IEnumerable<string>? trnrunArgs = null, string? label = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return ReplyInt64(_process.Request("add", AddFields(deckFile, trnrunArgs, label)), "runId");
    }

    /// <summary>Submits a deck with typed settings and returns its run ID once saved, not finished.</summary>
    /// <param name="deckFile">Deck to run; a relative one resolves from the current working directory.</param>
    /// <param name="settings">TRNRun options; see <see cref="SimulationSettings.ToCliArgs"/>.</param>
    /// <param name="label">Optional tag saved with the run.</param>
    /// <exception cref="FileNotFoundException">A set <see cref="SimulationSettings.TrnexePath"/> does not exist.</exception>
    /// <exception cref="RequestRejectedException">trnrund refused the run, with its reason.</exception>
    /// <exception cref="ClosedException">The daemon was shut down.</exception>
    /// <exception cref="DaemonExitedException">trnrund exited.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public long Add(string deckFile, SimulationSettings settings, string? label = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return Add(deckFile, settings.ToCliArgs(), label);
    }

    /// <summary>Submits a deck and returns its run ID once saved, without blocking; see <see cref="Add(string, IEnumerable{string}?, string?)"/>.</summary>
    /// <param name="deckFile">Deck to run; a relative one resolves from the current working directory, not the daemon's.</param>
    /// <param name="trnrunArgs">Raw TRNRun options, such as <c>--watchTmp:true</c>.</param>
    /// <param name="label">Optional tag saved with the run.</param>
    /// <param name="cancellationToken">Stops waiting for the reply; trnrund may still add the run.</param>
    public async Task<long> AddAsync(
        string deckFile, IEnumerable<string>? trnrunArgs = null, string? label = null, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        JsonElement reply = await _process.RequestAsync("add", AddFields(deckFile, trnrunArgs, label), null, cancellationToken)
            .ConfigureAwait(false);
        return ReplyInt64(reply, "runId");
    }

    /// <summary>Submits a deck with typed settings and returns its run ID once saved, without blocking; see <see cref="Add(string, SimulationSettings, string?)"/>.</summary>
    /// <param name="deckFile">Deck to run; a relative one resolves from the current working directory.</param>
    /// <param name="settings">TRNRun options; see <see cref="SimulationSettings.ToCliArgs"/>.</param>
    /// <param name="label">Optional tag saved with the run.</param>
    /// <param name="cancellationToken">Stops waiting for the reply; trnrund may still add the run.</param>
    public Task<long> AddAsync(
        string deckFile, SimulationSettings settings, string? label = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return AddAsync(deckFile, settings.ToCliArgs(), label, cancellationToken);
    }

    /// <summary>Stops a queued or running run, leaving a finished one unchanged.</summary>
    /// <remarks>A queued run is finished and <c>CANCELLED</c> on return; a running one becomes so once its TRNRun is killed.</remarks>
    /// <exception cref="RequestRejectedException">The run ID is unknown.</exception>
    /// <exception cref="ClosedException">The daemon was shut down.</exception>
    /// <exception cref="DaemonExitedException">trnrund exited.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public void Cancel(long runId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _ = _process.Request("cancel", writer => writer.WriteNumber("runId", runId));
    }

    /// <summary>Stops a queued or running run without blocking; see <see cref="Cancel"/>.</summary>
    /// <param name="runId">Run to stop.</param>
    /// <param name="cancellationToken">Stops waiting for the reply; trnrund may still cancel the run.</param>
    public async Task CancelAsync(long runId, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _ = await _process.RequestAsync("cancel", writer => writer.WriteNumber("runId", runId), null, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>Cancels queued runs, waits for running ones to finish, and waits for trnrund to exit.</summary>
    /// <param name="cancelRunning">Cancel running runs too.</param>
    /// <exception cref="DaemonExitedException">trnrund exited with an error.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public void Shutdown(bool cancelRunning = false) => Shutdown(Timeout.InfiniteTimeSpan, cancelRunning);

    /// <summary>Cancels queued runs, waits up to <paramref name="timeout"/> for running ones, and waits for trnrund to exit.</summary>
    /// <param name="timeout">Runs still running after this long are interrupted as by <see cref="Dispose"/>.</param>
    /// <param name="cancelRunning">Cancel running runs too.</param>
    /// <exception cref="DaemonExitedException">trnrund exited with an error.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public void Shutdown(TimeSpan timeout, bool cancelRunning = false)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _ = _process.Request("shutdown", ShutdownFields(cancelRunning));
        if (!_process.Wait(timeout))
        {
            _process.Close();
        }
    }

    /// <summary>Cancels queued runs, waits for running ones to finish, and waits for trnrund to exit, without blocking.</summary>
    /// <param name="cancelRunning">Cancel running runs too.</param>
    /// <param name="cancellationToken">
    /// Stops waiting: trnrund is closed as by <see cref="Dispose"/>, interrupting running runs, and
    /// <see cref="OperationCanceledException"/> is thrown.
    /// </param>
    /// <exception cref="DaemonExitedException">trnrund exited with an error.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public async Task ShutdownAsync(bool cancelRunning = false, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        try
        {
            _ = await _process.RequestAsync("shutdown", ShutdownFields(cancelRunning), null, cancellationToken).ConfigureAwait(false);
            await _process.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            await _process.CloseAsync().ConfigureAwait(false);
            throw;
        }
    }

    // -----------------------------------------------------------------
    // Following changes
    // -----------------------------------------------------------------

    /// <summary>Opens the daemon's database read-only; see <see cref="TrnrunDatabase.Open"/>.</summary>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public SqliteConnection OpenDatabase()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return TrnrunDatabase.Open(DatabasePath);
    }

    /// <summary>Blocks until trnrund saves a revision after <paramref name="afterRevision"/>.</summary>
    /// <remarks>
    /// Returns at once if one was already announced, so a change saved while you were reading is
    /// never missed. Everything trnrund saved is readable once it throws.
    /// </remarks>
    /// <exception cref="ClosedException">trnrund has exited with nothing newer, after a shutdown.</exception>
    /// <exception cref="DaemonExitedException">trnrund has exited with nothing newer, after a crash.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public void WaitForChanges(long afterRevision) => WaitForChanges(afterRevision, Timeout.InfiniteTimeSpan);

    /// <summary>Blocks until trnrund saves a revision after <paramref name="afterRevision"/>, or <paramref name="timeout"/> passes.</summary>
    /// <returns>True once it has; false if <paramref name="timeout"/> passes first. <see cref="TimeSpan.Zero"/> never blocks.</returns>
    /// <remarks>See <see cref="WaitForChanges(long)"/>.</remarks>
    /// <exception cref="ClosedException">trnrund has exited with nothing newer, after a shutdown.</exception>
    /// <exception cref="DaemonExitedException">trnrund has exited with nothing newer, after a crash.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed.</exception>
    public bool WaitForChanges(long afterRevision, TimeSpan timeout)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _process.WaitForChanges(afterRevision, timeout);
    }

    /// <summary>Waits until trnrund saves a revision after <paramref name="afterRevision"/>, without blocking.</summary>
    /// <remarks>See <see cref="WaitForChanges(long)"/>.</remarks>
    /// <param name="afterRevision">The latest revision already read.</param>
    /// <param name="cancellationToken">Stops waiting and throws <see cref="OperationCanceledException"/>.</param>
    /// <exception cref="ClosedException">trnrund has exited with nothing newer, after a shutdown or disposal.</exception>
    /// <exception cref="DaemonExitedException">trnrund has exited with nothing newer, after a crash.</exception>
    /// <exception cref="ObjectDisposedException">The daemon was disposed before the call.</exception>
    public Task WaitForChangesAsync(long afterRevision, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _process.WaitForChangesAsync(afterRevision, cancellationToken);
    }

    // -----------------------------------------------------------------
    // Closing
    // -----------------------------------------------------------------

    /// <summary>Interrupts unfinished runs, stops trnrund, and deletes a temporary database; safe to call again.</summary>
    /// <remarks>trnrund is killed, with its runs, if it has not exited 10 seconds after its stdin closes.</remarks>
    public void Dispose()
    {
        _disposed = true;
        _process.Close();
        DeleteTemporary(_temporary);
    }

    /// <summary>Interrupts unfinished runs, stops trnrund, and deletes a temporary database, without blocking; see <see cref="Dispose"/>.</summary>
    public async ValueTask DisposeAsync()
    {
        _disposed = true;
        await _process.CloseAsync().ConfigureAwait(false);
        DeleteTemporary(_temporary);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// <summary>Writes an <c>add</c> request's fields, with the deck made absolute now.</summary>
    private static Action<Utf8JsonWriter> AddFields(string deckFile, IEnumerable<string>? trnrunArgs, string? label)
    {
        string deck = Path.GetFullPath(deckFile);
        string[] args = trnrunArgs?.ToArray() ?? [];
        return writer =>
        {
            writer.WriteString("deckFile", deck);
            writer.WriteStartArray("trnrunArgs");
            foreach (string arg in args)
            {
                writer.WriteStringValue(arg);
            }

            writer.WriteEndArray();
            if (label is not null)
            {
                writer.WriteString("label", label);
            }
        };
    }

    /// <summary>Writes a <c>shutdown</c> request's fields.</summary>
    private static Action<Utf8JsonWriter> ShutdownFields(bool cancelRunning) =>
        writer => writer.WriteBoolean("cancelRunning", cancelRunning);

    /// <summary>Returns a reply's text field.</summary>
    /// <exception cref="TrnrunException">trnrund sent something else.</exception>
    internal static string ReplyString(JsonElement reply, string key) =>
        reply.TryGetProperty(key, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()!
            : throw new TrnrunException($"trnrund reply has no string '{key}': {reply.GetRawText()}");

    /// <summary>Returns a reply's integer field.</summary>
    /// <exception cref="TrnrunException">trnrund sent something else.</exception>
    internal static long ReplyInt64(JsonElement reply, string key) =>
        DaemonProcess.TryGetInt64(reply, key, out long value)
            ? value
            : throw new TrnrunException($"trnrund reply has no integer '{key}': {reply.GetRawText()}");

    /// <summary>Deletes a temporary database directory, if any; one still in use is left behind.</summary>
    private static void DeleteTemporary(DirectoryInfo? temporary)
    {
        try
        {
            temporary?.Delete(recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }
}
