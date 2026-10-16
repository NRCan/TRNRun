using System.Text;
using TRNRun.Internal;

namespace TRNRun;

/// <summary>Read-only view of a trnrund database, with typed results, independent of the daemon process.</summary>
/// <remarks>
/// <see cref="Poll"/> returns what changed since the previous call and remembers where it
/// stopped, so following runs needs no cursor bookkeeping. Calls from several threads are
/// serialized; each change is still handed out by <see cref="Poll"/> only once. Dispose it, or
/// use it in a <see langword="using"/> statement.
/// </remarks>
public sealed class Database : IDisposable
{
    /// <summary>The trnrund schema version this package reads.</summary>
    public const int SchemaVersion = 3;

    private readonly SqliteConnection _connection;
    // Serializes every call: a SQLite connection is not safe to share between threads.
    private readonly Lock _lock = new();
    private long _revision;
    private long _logId;
    private bool _disposed;

    /// <summary>Opens an existing database read-only.</summary>
    /// <param name="path">Database path; a relative one uses the current working directory.</param>
    /// <param name="afterRevision">
    /// <see cref="Poll"/> starts after this revision; the default reads the whole history, and
    /// <see cref="SeekEnd"/> skips it.
    /// </param>
    /// <param name="afterLogId"><see cref="Poll"/> starts after this log ID.</param>
    /// <exception cref="DatabaseException">SQLite cannot open it, such as when it does not exist.</exception>
    /// <exception cref="InvalidDataException">Its schema version is not <see cref="SchemaVersion"/>; it is closed first.</exception>
    public Database(string path, long afterRevision = 0, long afterLogId = 0)
    {
        Path = System.IO.Path.GetFullPath(path);
        _revision = afterRevision;
        _logId = afterLogId;
        _connection = SqliteConnection.Open(Path, readOnly: true);
        try
        {
            CheckSchema();
        }
        catch
        {
            _connection.Dispose();
            throw;
        }
    }

    /// <summary>Absolute path of the database.</summary>
    public string Path { get; }

    /// <summary>Largest run revision <see cref="Poll"/> has returned or skipped.</summary>
    public long Revision
    {
        get { lock (_lock) { return _revision; } }
    }

    /// <summary>Largest log ID <see cref="Poll"/> has returned or skipped.</summary>
    public long LogId
    {
        get { lock (_lock) { return _logId; } }
    }

    /// <summary>Throws unless the database has the schema this package reads.</summary>
    private void CheckSchema()
    {
        long version = (long)_connection.Query("PRAGMA user_version")[0][0]!;
        if (version != SchemaVersion)
        {
            throw new InvalidDataException($"Unsupported TRNRun database schema {version}; expected {SchemaVersion}");
        }
    }

    // -----------------------------------------------------------------
    // Following changes
    // -----------------------------------------------------------------

    /// <summary>Returns the runs and logs saved since the previous poll, and advances past them.</summary>
    /// <remarks>Runs and logs are read from one snapshot, so the logs saved with each returned run are included.</remarks>
    public Changes Poll()
    {
        List<DatabaseRow> runRows;
        List<DatabaseRow> logRows;
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            using (Snapshot())
            {
                runRows = _connection.Query("SELECT * FROM runs WHERE revision > ? ORDER BY revision", [_revision]);
                logRows = _connection.Query("SELECT * FROM logs WHERE log_id > ? ORDER BY log_id", [_logId]);
            }

            var changes = new Changes(
                runRows.Select(RowParser.ParseRun).ToArray(),
                logRows.Select(RowParser.ParseLog).ToArray());
            if (changes.Runs.Count > 0)
            {
                _revision = changes.Runs[^1].Revision;
            }

            if (changes.Logs.Count > 0)
            {
                _logId = changes.Logs[^1].LogId;
            }

            return changes;
        }
    }

    /// <summary>Skips everything saved so far; the next <see cref="Poll"/> returns only later changes.</summary>
    public void SeekEnd()
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            using (Snapshot())
            {
                _revision = (long)_connection.Query("SELECT coalesce(max(revision), 0) FROM runs")[0][0]!;
                _logId = (long)_connection.Query("SELECT coalesce(max(log_id), 0) FROM logs")[0][0]!;
            }
        }
    }

    // -----------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------

    /// <summary>Returns a run's current snapshot, or <see langword="null"/> if its ID is unknown.</summary>
    public SimulationInfo? GetRun(long runId)
    {
        List<DatabaseRow> rows = Query("SELECT * FROM runs WHERE run_id = ?", [runId]);
        return rows.Count == 0 ? null : RowParser.ParseRun(rows[0]);
    }

    /// <summary>Returns a run's logs, oldest first; empty when there are none.</summary>
    public IReadOnlyList<LogEvent> GetLogs(long runId) =>
        Query("SELECT * FROM logs WHERE run_id = ? ORDER BY log_id", [runId]).Select(RowParser.ParseLog).ToArray();

    /// <summary>Returns the runs of one session, in one state, or both, in the order they last changed.</summary>
    /// <remarks>With neither, returns every run.</remarks>
    public IReadOnlyList<SimulationInfo> GetRuns(long? sessionId = null, SimulationState? state = null)
    {
        var conditions = new List<string>();
        var parameters = new List<object?>();
        if (sessionId is not null)
        {
            conditions.Add("session_id = ?");
            parameters.Add(sessionId);
        }

        if (state is not null)
        {
            conditions.Add("state = ?");
            parameters.Add(RowParser.StateName(state.Value));
        }

        var sql = new StringBuilder("SELECT * FROM runs");
        if (conditions.Count > 0)
        {
            sql.Append(" WHERE ").AppendJoin(" AND ", conditions);
        }

        sql.Append(" ORDER BY revision");
        return Query(sql.ToString(), parameters).Select(RowParser.ParseRun).ToArray();
    }

    /// <summary>Returns the number of runs in each state, every state included, of one session or all.</summary>
    public IReadOnlyDictionary<SimulationState, int> CountRunsByState(long? sessionId = null)
    {
        List<DatabaseRow> rows = sessionId is null
            ? Query("SELECT state, count(*) FROM runs GROUP BY state", [])
            : Query("SELECT state, count(*) FROM runs WHERE session_id = ? GROUP BY state", [sessionId]);
        Dictionary<SimulationState, int> counts = Enum.GetValues<SimulationState>().ToDictionary(state => state, _ => 0);
        foreach (DatabaseRow row in rows)
        {
            counts[RowParser.ParseState((string)row[0]!)] = (int)(long)row[1]!;
        }

        return counts;
    }

    /// <summary>Runs a custom read-only query and returns its rows, readable by column name.</summary>
    /// <remarks>
    /// Bind values with <c>?</c> parameters rather than formatting them into
    /// <paramref name="sql"/>. Parameters may be <see langword="null"/>, strings, integers,
    /// floating-point numbers, Booleans, byte arrays, or a <see cref="SimulationState"/>, which
    /// binds as its saved name. Every row is read before this returns, keeping reads short.
    /// </remarks>
    /// <exception cref="ArgumentException">The SQL holds more than one statement, or the parameters do not match it.</exception>
    /// <exception cref="DatabaseException">SQLite rejects the query, such as one that writes.</exception>
    public IReadOnlyList<DatabaseRow> Execute(string sql, params object?[] parameters) =>
        Query(sql, parameters ?? []);

    /// <summary>Runs one query under the lock.</summary>
    private List<DatabaseRow> Query(string sql, IReadOnlyList<object?> parameters)
    {
        lock (_lock)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            return _connection.Query(sql, parameters);
        }
    }

    /// <summary>Reads every query until disposal from one consistent database state; call under the lock.</summary>
    private SnapshotScope Snapshot()
    {
        _connection.Execute("BEGIN");
        return new SnapshotScope(_connection);
    }

    /// <summary>Ends a read transaction when disposed.</summary>
    private readonly struct SnapshotScope(SqliteConnection connection) : IDisposable
    {
        /// <summary>Commits the read transaction.</summary>
        public void Dispose() => connection.Execute("COMMIT");
    }

    // -----------------------------------------------------------------
    // Closing
    // -----------------------------------------------------------------

    /// <summary>Closes the connection. Safe to call more than once.</summary>
    public void Dispose()
    {
        lock (_lock)
        {
            _disposed = true;
            _connection.Dispose();
        }
    }
}
