using System.Text.Json;
using TRNRun.Internal;

namespace TRNRun;

/// <summary>Starts trnrund, submits runs to it, and follows them as it saves them.</summary>
/// <remarks>
/// <para>
/// trnrund numbers each run and saves every change to its SQLite database, and announces each
/// batch of changes on its stdout. <see cref="Wait"/> blocks until one arrives and returns what
/// changed; <see cref="Poll"/> returns it without blocking. Both throw once trnrund has exited
/// unexpectedly and everything it saved has been returned, so a loop over them never hangs on a
/// crashed daemon. <see cref="Database"/> answers any other question about the runs.
/// </para>
/// <para>
/// Every member may be called from any thread. <see cref="Poll"/> and <see cref="Wait"/> hand
/// out each change once, so call them from one consumer; other readers open their own
/// <see cref="TRNRun.Database"/> and block in <see cref="WaitForChange"/>.
/// </para>
/// </remarks>
public sealed class Daemon : IDisposable
{
    /// <summary>How long a request waits for trnrund's reply by default.</summary>
    public static readonly TimeSpan DefaultRequestTimeout = TimeSpan.FromSeconds(60);

    private readonly DaemonProcess _process;
    private readonly DirectoryInfo? _temporary;

    /// <summary>Starts the daemon, waits for it to be ready, then opens its database.</summary>
    /// <param name="databasePath">
    /// Database holding the runs. Without one, the runs are kept in a temporary database,
    /// deleted by <see cref="Dispose"/>. A given database is created if missing, but its
    /// directory must exist; an existing one keeps its runs and logs, and the daemon continues
    /// its run numbers in a new session.
    /// </param>
    /// <param name="maxConcurrent">Simulations run at once; by default one less than the CPU count, at least 1.</param>
    /// <param name="trnrundPath">trnrund executable; by default <see cref="DefaultTrnrundPath"/>.</param>
    /// <param name="trnrunPath">TRNRun executable every run is started with; by default <see cref="DefaultTrnrunPath"/>.</param>
    /// <param name="requestTimeout">How long a request waits for its reply before throwing <see cref="TimeoutException"/>; by default <see cref="DefaultRequestTimeout"/>.</param>
    /// <remarks>Relative paths use the current working directory.</remarks>
    /// <exception cref="FileNotFoundException">trnrund does not exist.</exception>
    /// <exception cref="DaemonException">trnrund failed to start, with its message.</exception>
    public Daemon(
        string? databasePath = null,
        int? maxConcurrent = null,
        string? trnrundPath = null,
        string? trnrunPath = null,
        TimeSpan? requestTimeout = null)
    {
        // Unwound by Dispose(): the database, then the daemon, then a temporary directory.
        DirectoryInfo? temporary = null;
        DaemonProcess? process = null;
        Database? database = null;
        try
        {
            if (databasePath is null)
            {
                temporary = Directory.CreateTempSubdirectory("trnrun-");
                databasePath = Path.Combine(temporary.FullName, "runs.sqlite3");
            }

            var settings = new DaemonSettings(trnrunPath ?? DefaultTrnrunPath, maxConcurrent, databasePath);
            process = new DaemonProcess(
                trnrundPath ?? DefaultTrnrundPath,
                settings.ToCliArgs(),
                requestTimeout ?? DefaultRequestTimeout);
            JsonElement ready = process.Request("ready");
            DatabasePath = ReplyString(ready, "databasePath");
            SessionId = ReplyInt64(ready, "sessionId");
            StartRevision = ReplyInt64(ready, "revision");
            StartLogId = ReplyInt64(ready, "logId");
            database = new Database(DatabasePath, StartRevision, StartLogId);
        }
        catch
        {
            database?.Dispose();
            process?.Close();
            DeleteTemporary(temporary);
            throw;
        }

        _process = process;
        _temporary = temporary;
        Database = database;
    }

    /// <summary>The trnrund.exe bundled in <c>native/</c> beside the application.</summary>
    public static string DefaultTrnrundPath => Path.Combine(AppContext.BaseDirectory, "native", "trnrund.exe");

    /// <summary>The trnrun.exe bundled in <c>native/</c> beside the application.</summary>
    public static string DefaultTrnrunPath => Path.Combine(AppContext.BaseDirectory, "native", "trnrun.exe");

    /// <summary>The database path trnrund reported, not a guessed filename.</summary>
    public string DatabasePath { get; }

    /// <summary>This daemon's session, recorded on every run it adds.</summary>
    public long SessionId { get; }

    /// <summary>The latest run revision when the daemon started; a reader that starts there sees only this daemon's changes.</summary>
    public long StartRevision { get; }

    /// <summary>The latest log ID when the daemon started.</summary>
    public long StartLogId { get; }

    /// <summary>Read-only view of the runs, following from <see cref="StartRevision"/> and <see cref="StartLogId"/>.</summary>
    public Database Database { get; }

    /// <summary>trnrund's process ID.</summary>
    internal int ProcessId => _process.ProcessId;

    // -----------------------------------------------------------------
    // Requests
    // -----------------------------------------------------------------

    /// <summary>Submits a deck and returns the run ID trnrund assigned; returns after saving, not finishing.</summary>
    /// <param name="deckFile">Deck to run; a relative one resolves from the current working directory now, not from the daemon's.</param>
    /// <param name="trnrunArgs">Raw TRNRun options, such as <c>--watchTmp:true</c>.</param>
    /// <param name="label">Optional tag saved with the run.</param>
    /// <exception cref="ArgumentException">trnrund rejected the run, with its reason.</exception>
    /// <exception cref="DaemonException">trnrund has exited or is closed.</exception>
    public long Add(string deckFile, IEnumerable<string>? trnrunArgs = null, string? label = null)
    {
        string deck = Path.GetFullPath(deckFile);
        string[] args = trnrunArgs?.ToArray() ?? [];
        JsonElement reply = _process.Request("add", writer =>
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
        });
        return ReplyInt64(reply, "runId");
    }

    /// <summary>Submits a deck with typed settings and returns the run ID trnrund assigned.</summary>
    /// <param name="deckFile">Deck to run; a relative one resolves from the current working directory.</param>
    /// <param name="settings">TRNRun options; see <see cref="SimulationSettings.ToCliArgs"/>.</param>
    /// <param name="label">Optional tag saved with the run.</param>
    /// <exception cref="FileNotFoundException">A set <see cref="SimulationSettings.TrnexePath"/> does not exist.</exception>
    /// <exception cref="ArgumentException">trnrund rejected the run, with its reason.</exception>
    /// <exception cref="DaemonException">trnrund has exited or is closed.</exception>
    public long Add(string deckFile, SimulationSettings settings, string? label = null)
    {
        ArgumentNullException.ThrowIfNull(settings);
        return Add(deckFile, settings.ToCliArgs(), label);
    }

    /// <summary>Stops a queued or running run; returns after recording it, not finishing.</summary>
    /// <remarks>
    /// A queued run is finished and <c>CANCELLED</c> on return; a running one becomes so once its
    /// TRNRun is killed. A finished run is left unchanged.
    /// </remarks>
    /// <exception cref="ArgumentException">The run ID is unknown.</exception>
    /// <exception cref="DaemonException">trnrund has exited or is closed.</exception>
    public void Cancel(long runId) =>
        _ = _process.Request("cancel", writer => writer.WriteNumber("runId", runId));

    /// <summary>Cancels queued runs, finishes or kills running ones, and waits for trnrund to exit.</summary>
    /// <param name="cancelRunning">Kill running runs instead of waiting for them.</param>
    /// <param name="timeout">
    /// If runs are still running after this long, stdin is closed, which saves them as
    /// interrupted and kills them; <see langword="null"/> waits indefinitely.
    /// </param>
    /// <remarks><see cref="Database"/> stays open until <see cref="Dispose"/>.</remarks>
    /// <exception cref="DaemonException">trnrund exited with an error, or had already exited.</exception>
    public void Shutdown(bool cancelRunning = false, TimeSpan? timeout = null)
    {
        _ = _process.Request("shutdown", writer => writer.WriteBoolean("cancelRunning", cancelRunning));
        if (!_process.Wait(timeout))
        {
            _process.Close();
        }
    }

    // -----------------------------------------------------------------
    // Following changes
    // -----------------------------------------------------------------

    /// <summary>Returns the runs and logs saved since the previous <see cref="Poll"/> or <see cref="Wait"/>.</summary>
    /// <exception cref="DaemonException">
    /// trnrund exited before <see cref="Shutdown"/> or <see cref="Dispose"/>, and every change it
    /// saved has been returned.
    /// </exception>
    public Changes Poll()
    {
        // Checked before reading: once trnrund's stdout ended, everything it saved is readable.
        DaemonException? exitError = _process.GetExitError();
        Changes changes = Database.Poll();
        if (changes.IsEmpty && exitError is not null)
        {
            throw exitError;
        }

        return changes;
    }

    /// <summary>Blocks until trnrund saves more changes, then returns them as <see cref="Poll"/> does.</summary>
    /// <param name="timeout">How long to wait; <see langword="null"/> waits indefinitely.</param>
    /// <returns>
    /// The changes, at once if some are already waiting, or empty <see cref="Changes"/> if the
    /// timeout passes first. After <see cref="Shutdown"/> it no longer blocks.
    /// </returns>
    /// <exception cref="DaemonException">As <see cref="Poll"/>.</exception>
    public Changes Wait(TimeSpan? timeout = null)
    {
        _ = _process.WaitForChange(Database.Revision, timeout);
        return Poll();
    }

    /// <summary>Blocks until trnrund announces a revision after <paramref name="afterRevision"/>, or exits.</summary>
    /// <returns>False if <paramref name="timeout"/> passes first; <see langword="null"/> waits indefinitely.</returns>
    /// <remarks>For readers with their own <see cref="TRNRun.Database"/>.</remarks>
    public bool WaitForChange(long afterRevision, TimeSpan? timeout = null) =>
        _process.WaitForChange(afterRevision, timeout);

    /// <summary>Returns how trnrund exited if it ended before <see cref="Shutdown"/> or <see cref="Dispose"/>, else <see langword="null"/>.</summary>
    public DaemonException? GetExitError() => _process.GetExitError();

    // -----------------------------------------------------------------
    // Closing
    // -----------------------------------------------------------------

    /// <summary>Closes <see cref="Database"/>, closes stdin, interrupting unfinished runs, and waits for trnrund.</summary>
    /// <remarks>
    /// trnrund is killed, with its runs, if it has not exited 10 seconds after stdin closes. A
    /// temporary database is then deleted. Safe to call more than once, including after the
    /// daemon crashed.
    /// </remarks>
    public void Dispose()
    {
        Database.Dispose();
        _process.Close();
        DeleteTemporary(_temporary);
    }

    // -----------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------

    /// <summary>Returns a reply's text field.</summary>
    /// <exception cref="DaemonException">trnrund sent something else.</exception>
    internal static string ReplyString(JsonElement reply, string key) =>
        reply.TryGetProperty(key, out JsonElement value) && value.ValueKind == JsonValueKind.String
            ? value.GetString()!
            : throw new DaemonException($"trnrund reply has no string '{key}': {reply.GetRawText()}");

    /// <summary>Returns a reply's integer field.</summary>
    /// <exception cref="DaemonException">trnrund sent something else.</exception>
    internal static long ReplyInt64(JsonElement reply, string key) =>
        DaemonProcess.TryGetInt64(reply, key, out long value)
            ? value
            : throw new DaemonException($"trnrund reply has no integer '{key}': {reply.GetRawText()}");

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
