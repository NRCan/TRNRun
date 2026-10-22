using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text.Json;
using Microsoft.Data.Sqlite;
using TRNRun.Internal;

namespace TRNRun;

/// <summary>A running trnrund: submit runs, and follow its database as it changes.</summary>
/// <remarks>
/// Every member is thread-safe. Once trnrund has shut down, requests throw <see cref="DaemonClosedException"/>;
/// once it crashed, <see cref="DaemonExitedException"/>; once disposed, <see cref="ObjectDisposedException"/>.
/// </remarks>
public sealed class Daemon : IDisposable, IAsyncDisposable
{
    private readonly DaemonProcess _process;
    private readonly DirectoryInfo? _temporary;
    private volatile bool _disposed;

    /// <summary>Wraps a started trnrund from its <c>ready</c> reply.</summary>
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

    /// <summary>Where the database stood when the daemon started; read after it to see only its changes.</summary>
    public ChangePosition StartPosition { get; }

    /// <summary>trnrund's process ID.</summary>
    internal int ProcessId => _process.ProcessId;

    /// <summary>Starts trnrund and waits until it is ready; by default with a temporary database and the bundled executables.</summary>
    /// <exception cref="FileNotFoundException">trnrund does not exist.</exception>
    /// <exception cref="DaemonExitedException">trnrund failed to start, with its message.</exception>
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

    /// <summary>Async version of <see cref="Start"/>; cancelling closes trnrund.</summary>
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

    /// <summary>Starts the trnrund process, with a temporary database directory if the options name none.</summary>
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

    /// <summary>Submits a deck, relative to the current directory, with raw TRNRun options; returns its run ID once saved, not finished.</summary>
    /// <exception cref="RequestRejectedException">trnrund refused the run, with its reason.</exception>
    public long Add(string deckFile, IEnumerable<string>? trnrunArgs = null, string? label = null)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return ReplyInt64(_process.Request("add", AddFields(deckFile, trnrunArgs, label)), "runId");
    }

    /// <summary>Same as <see cref="Add(string, IEnumerable{string}?, string?)"/>, with typed settings.</summary>
    public long Add(string deckFile, SimulationSettings settings, string? label = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return Add(deckFile, settings.ToCliArgs(), label);
    }

    /// <summary>Async version of <see cref="Add(string, IEnumerable{string}?, string?)"/>; once cancelled, trnrund may still add the run.</summary>
    public async Task<long> AddAsync(
        string deckFile, IEnumerable<string>? trnrunArgs = null, string? label = null, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        JsonElement reply = await _process.RequestAsync("add", AddFields(deckFile, trnrunArgs, label), null, cancellationToken)
            .ConfigureAwait(false);
        return ReplyInt64(reply, "runId");
    }

    /// <summary>Async version of <see cref="Add(string, SimulationSettings, string?)"/>; once cancelled, trnrund may still add the run.</summary>
    public Task<long> AddAsync(
        string deckFile, SimulationSettings settings, string? label = null, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return AddAsync(deckFile, settings.ToCliArgs(), label, cancellationToken);
    }

    /// <summary>Stops a queued run at once, or a running one once its TRNRun is killed; a finished one is left unchanged.</summary>
    /// <exception cref="RequestRejectedException">The run ID is unknown.</exception>
    public void Cancel(long runId)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _ = _process.Request("cancel", writer => writer.WriteNumber("runId", runId));
    }

    /// <summary>Async version of <see cref="Cancel"/>; once cancelled, trnrund may still cancel the run.</summary>
    public async Task CancelAsync(long runId, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _ = await _process.RequestAsync("cancel", writer => writer.WriteNumber("runId", runId), null, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>Cancels queued runs, and running ones too with <paramref name="cancelRunning"/>, then waits for the rest and for trnrund to exit.</summary>
    public void Shutdown(bool cancelRunning = false) => Shutdown(Timeout.InfiniteTimeSpan, cancelRunning);

    /// <summary>Same as <see cref="Shutdown(bool)"/>, interrupting runs still running after <paramref name="timeout"/> as <see cref="Dispose"/> does.</summary>
    public void Shutdown(TimeSpan timeout, bool cancelRunning = false)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        _ = _process.Request("shutdown", ShutdownFields(cancelRunning));
        if (!_process.Wait(timeout))
        {
            _process.Close();
        }
    }

    /// <summary>Async version of <see cref="Shutdown(bool)"/>; cancelling interrupts running runs as <see cref="Dispose"/> does.</summary>
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

    /// <summary>Opens the daemon's database read-only; see <see cref="TrnrunDatabase.Open"/>.</summary>
    public SqliteConnection OpenDatabase()
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return TrnrunDatabase.Open(DatabasePath);
    }

    /// <summary>Blocks until trnrund saves a revision after <paramref name="afterRevision"/>, at once if it already has; throws only once trnrund ended with nothing newer.</summary>
    public void WaitForChanges(long afterRevision) => WaitForChanges(afterRevision, Timeout.InfiniteTimeSpan);

    /// <summary>Same as <see cref="WaitForChanges(long)"/>, returning false if <paramref name="timeout"/> passes first.</summary>
    public bool WaitForChanges(long afterRevision, TimeSpan timeout)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _process.WaitForChanges(afterRevision, timeout);
    }

    /// <summary>Async version of <see cref="WaitForChanges(long)"/>.</summary>
    public Task WaitForChangesAsync(long afterRevision, CancellationToken cancellationToken = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        return _process.WaitForChangesAsync(afterRevision, cancellationToken);
    }

    /// <summary>Yields each change saved after <paramref name="after"/>, read through <paramref name="connection"/>, until trnrund closes.</summary>
    public IEnumerable<Changes> Follow(SqliteConnection connection, ChangePosition after)
    {
        while (true)
        {
            try
            {
                WaitForChanges(after.Revision);
            }
            catch (DaemonClosedException)
            {
                yield break;
            }

            Changes changes = connection.ReadChanges(after);
            after = changes.Next;
            yield return changes;
        }
    }

    /// <summary>Async version of <see cref="Follow(SqliteConnection, ChangePosition)"/>.</summary>
    public async IAsyncEnumerable<Changes> FollowAsync(
        SqliteConnection connection, ChangePosition after, [EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        while (true)
        {
            try
            {
                await WaitForChangesAsync(after.Revision, cancellationToken).ConfigureAwait(false);
            }
            catch (DaemonClosedException)
            {
                yield break;
            }

            Changes changes = connection.ReadChanges(after);
            after = changes.Next;
            yield return changes;
        }
    }

    /// <summary>Yields this daemon's changes from <see cref="StartPosition"/>, through a connection of its own that closes when the loop ends.</summary>
    public IEnumerable<Changes> Follow()
    {
        using SqliteConnection connection = OpenDatabase();
        foreach (Changes changes in Follow(connection, StartPosition))
        {
            yield return changes;
        }
    }

    /// <summary>Async version of <see cref="Follow()"/>.</summary>
    public async IAsyncEnumerable<Changes> FollowAsync([EnumeratorCancellation] CancellationToken cancellationToken = default)
    {
        using SqliteConnection connection = OpenDatabase();
        await foreach (Changes changes in FollowAsync(connection, StartPosition, cancellationToken).ConfigureAwait(false))
        {
            yield return changes;
        }
    }

    /// <summary>Interrupts unfinished runs, stops trnrund (killing it after 10 s), and deletes a temporary database; safe to repeat.</summary>
    public void Dispose()
    {
        _disposed = true;
        _process.Close();
        DeleteTemporary(_temporary);
    }

    /// <summary>Async version of <see cref="Dispose"/>.</summary>
    public async ValueTask DisposeAsync()
    {
        _disposed = true;
        await _process.CloseAsync().ConfigureAwait(false);
        DeleteTemporary(_temporary);
    }

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

    /// <summary>Returns a reply's text field, or throws <see cref="TrnrunException"/>.</summary>
    internal static string ReplyString(JsonElement reply, string key) =>
        reply.TryGetProperty(key, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()!
            : throw new TrnrunException($"trnrund reply has no string '{key}': {reply.GetRawText()}");

    /// <summary>Returns a reply's integer field, or throws <see cref="TrnrunException"/>.</summary>
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
