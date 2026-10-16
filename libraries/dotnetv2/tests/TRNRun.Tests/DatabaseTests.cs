using TRNRun.Internal;

namespace TRNRun.Tests;

/// <summary>Tests for <see cref="Database"/>: the read-only view of a trnrund database.</summary>
public sealed class DatabaseTests : IDisposable
{
    private readonly TempDirectory _temp = new();
    private readonly string _path;
    private readonly SqliteConnection _writer;
    private readonly Database _database;

    /// <summary>Creates a database with trnrund's schema, a writer standing in for trnrund, and a reader.</summary>
    public DatabaseTests()
    {
        _path = _temp.File("runs.sqlite3");
        _writer = TestDatabase.Create(_path);
        _database = new Database(_path);
    }

    /// <summary>Closes both connections and deletes the database.</summary>
    public void Dispose()
    {
        _database.Dispose();
        _writer.Dispose();
        _temp.Dispose();
    }

    // -----------------------------------------------------------------
    // Opening and closing
    // -----------------------------------------------------------------

    /// <summary>Never create a database: trnrund owns it.</summary>
    [Fact]
    public void OpenMissingDatabaseFails()
    {
        string missing = _temp.File("missing.sqlite3");

        var error = Assert.Throws<DatabaseException>(() => new Database(missing));

        Assert.Equal(14, error.ResultCode & 0xFF); // SQLITE_CANTOPEN
        Assert.False(File.Exists(missing));
    }

    /// <summary>Refuse a database this package cannot read, without leaving it open.</summary>
    [Fact]
    public void OpenRejectsAnotherSchemaVersionAndCloses()
    {
        string path = _temp.File("old.sqlite3");
        TestDatabase.Create(path, version: 2).Dispose();

        var error = Assert.Throws<InvalidDataException>(() => new Database(path));

        Assert.Equal("Unsupported TRNRun database schema 2; expected 3", error.Message);
        File.Delete(path); // Fails on Windows while a connection still holds the file.
    }

    /// <summary>Never let a reader write to trnrund's database.</summary>
    [Fact]
    public void DatabaseIsReadOnly()
    {
        var error = Assert.Throws<DatabaseException>(() => _database.Execute("INSERT INTO sessions (started_at) VALUES ('now')"));
        Assert.Contains("readonly", error.Message);
    }

    /// <summary>Close once, allow closing again, and refuse later queries.</summary>
    [Fact]
    public void DisposeIsIdempotentAndEndsQueries()
    {
        var database = new Database(_path);
        database.Dispose();
        database.Dispose();

        Assert.Throws<ObjectDisposedException>(() => database.GetRun(1));
        Assert.Throws<ObjectDisposedException>(() => database.Poll());
    }

    // -----------------------------------------------------------------
    // Following changes
    // -----------------------------------------------------------------

    /// <summary>Advance past each poll's runs and logs, so nothing is returned twice.</summary>
    [Fact]
    public void PollReturnsEverythingThenOnlyWhatIsNew()
    {
        long first = TestDatabase.InsertRun(_writer);
        long second = TestDatabase.InsertRun(_writer);
        long log = TestDatabase.InsertLog(_writer, first, ("message", "hello"));

        Changes changes = _database.Poll();

        Assert.Equal([first, second], changes.Runs.Select(info => info.RunId));
        Assert.Equal([log], changes.Logs.Select(entry => entry.LogId));
        Assert.Equal((2, log), (_database.Revision, _database.LogId));
        Assert.True(_database.Poll().IsEmpty);

        TestDatabase.UpdateRun(_writer, first, ("state", "RUNNING"));
        long laterLog = TestDatabase.InsertLog(_writer, first, ("severity", "Warning"));

        changes = _database.Poll();

        Assert.Equal([(first, SimulationState.Running)], changes.Runs.Select(info => (info.RunId, info.State)));
        Assert.Equal([laterLog], changes.Logs.Select(entry => entry.LogId));
    }

    /// <summary>Return each run once, at its latest revision, ordered by when it last changed.</summary>
    [Fact]
    public void PollReturnsTheLatestSnapshotInChangeOrder()
    {
        long first = TestDatabase.InsertRun(_writer);
        long second = TestDatabase.InsertRun(_writer);
        TestDatabase.UpdateRun(_writer, first, ("state", "RUNNING"));
        TestDatabase.UpdateRun(_writer, first, ("state", "FINISHED"), ("trnrun_status", "DONE"), ("succeeded", 1), ("exit_code", 0));

        Changes changes = _database.Poll();

        Assert.Equal([second, first], changes.Runs.Select(info => info.RunId));
        Assert.Equal(SimulationState.Finished, changes.Runs[^1].State);
        Assert.Equal(4, changes.Runs[^1].Revision);
        Assert.Equal(4, _database.Revision);
    }

    /// <summary>Skip the history before the given revision and log ID.</summary>
    [Fact]
    public void PollStartsAfterTheGivenRevisionAndLog()
    {
        long old = TestDatabase.InsertRun(_writer);
        long oldLog = TestDatabase.InsertLog(_writer, old);
        long recent = TestDatabase.InsertRun(_writer);
        long recentLog = TestDatabase.InsertLog(_writer, recent);

        using var database = new Database(_path, afterRevision: 1, afterLogId: oldLog);
        Changes changes = database.Poll();

        Assert.Equal([recent], changes.Runs.Select(info => info.RunId));
        Assert.Equal([recentLog], changes.Logs.Select(entry => entry.LogId));
    }

    /// <summary>Return only what is saved after SeekEnd.</summary>
    [Fact]
    public void SeekEndSkipsTheHistory()
    {
        long runId = TestDatabase.InsertRun(_writer);
        TestDatabase.InsertLog(_writer, runId);

        _database.SeekEnd();

        Assert.Equal((1, 1), (_database.Revision, _database.LogId));
        Assert.True(_database.Poll().IsEmpty);
        TestDatabase.UpdateRun(_writer, runId, ("state", "RUNNING"));
        Assert.Equal([2], _database.Poll().Runs.Select(info => info.Revision));
    }

    /// <summary>Start from zero when nothing was saved yet.</summary>
    [Fact]
    public void SeekEndOfAnEmptyDatabase()
    {
        _database.SeekEnd();

        Assert.Equal((0, 0), (_database.Revision, _database.LogId));
    }

    // -----------------------------------------------------------------
    // Queries
    // -----------------------------------------------------------------

    /// <summary>Return a run's current snapshot, or null for an unknown ID.</summary>
    [Fact]
    public void GetRun()
    {
        long runId = TestDatabase.InsertRun(_writer, ("label", "baseline"));
        TestDatabase.UpdateRun(_writer, runId, ("state", "RUNNING"));

        SimulationInfo? info = _database.GetRun(runId);

        Assert.NotNull(info);
        Assert.Equal(("baseline", SimulationState.Running, 2L), (info.Label, info.State, info.Revision));
        Assert.Null(_database.GetRun(999));
    }

    /// <summary>Return a run's logs oldest first, without other runs' logs.</summary>
    [Fact]
    public void GetLogs()
    {
        long first = TestDatabase.InsertRun(_writer);
        long second = TestDatabase.InsertRun(_writer);
        long a = TestDatabase.InsertLog(_writer, first, ("message", "a"));
        TestDatabase.InsertLog(_writer, second, ("message", "other"));
        long b = TestDatabase.InsertLog(_writer, first, ("message", "b"));

        Assert.Equal([a, b], _database.GetLogs(first).Select(log => log.LogId));
        Assert.Equal(["a", "b"], _database.GetLogs(first).Select(log => log.Message));
        Assert.Empty(_database.GetLogs(999));
    }

    /// <summary>Combine the optional filters, and order by last change.</summary>
    [Fact]
    public void GetRunsFiltersBySessionAndState()
    {
        long a = TestDatabase.InsertRun(_writer, ("session_id", 1), ("state", "FINISHED"));
        long b = TestDatabase.InsertRun(_writer, ("session_id", 2), ("state", "QUEUED"));
        long c = TestDatabase.InsertRun(_writer, ("session_id", 2), ("state", "FINISHED"));
        TestDatabase.UpdateRun(_writer, a, ("label", "touched")); // Now the latest change.

        Assert.Equal([b, c, a], _database.GetRuns().Select(info => info.RunId));
        Assert.Equal([b, c], _database.GetRuns(sessionId: 2).Select(info => info.RunId));
        Assert.Equal([c, a], _database.GetRuns(state: SimulationState.Finished).Select(info => info.RunId));
        Assert.Equal([c], _database.GetRuns(sessionId: 2, state: SimulationState.Finished).Select(info => info.RunId));
        Assert.Empty(_database.GetRuns(sessionId: 3));
    }

    /// <summary>Count every state, including those without runs, overall or per session.</summary>
    [Fact]
    public void CountRunsByState()
    {
        TestDatabase.InsertRun(_writer, ("session_id", 1), ("state", "FINISHED"));
        TestDatabase.InsertRun(_writer, ("session_id", 2), ("state", "FINISHED"));
        TestDatabase.InsertRun(_writer, ("session_id", 2), ("state", "RUNNING"));

        Assert.Equal(
            new Dictionary<SimulationState, int>
            {
                [SimulationState.Queued] = 0,
                [SimulationState.Running] = 1,
                [SimulationState.Finished] = 2,
            },
            _database.CountRunsByState());
        Assert.Equal(
            new Dictionary<SimulationState, int>
            {
                [SimulationState.Queued] = 0,
                [SimulationState.Running] = 0,
                [SimulationState.Finished] = 1,
            },
            _database.CountRunsByState(sessionId: 1));
    }

    /// <summary>Report zero for every state.</summary>
    [Fact]
    public void CountRunsByStateOfAnEmptyDatabase() =>
        Assert.All(_database.CountRunsByState(), pair => Assert.Equal(0, pair.Value));

    /// <summary>Run a custom query with bound parameters and named columns.</summary>
    [Fact]
    public void ExecuteReturnsRowsByColumnName()
    {
        long runId = TestDatabase.InsertRun(_writer, ("label", "custom"));

        DatabaseRow row = Assert.Single(_database.Execute("SELECT run_id, label FROM runs WHERE label = ?", "custom"));

        Assert.Equal(runId, row["run_id"]);
        Assert.Equal(runId, row["RUN_ID"]); // SQLite's names are case-insensitive.
        Assert.Equal("custom", row.GetString("label"));
        Assert.Equal(2, row.Count);
        Assert.Throws<KeyNotFoundException>(() => row["missing"]);
    }

    /// <summary>Bind a state by its saved name, and read SQLite's value types.</summary>
    [Fact]
    public void ExecuteBindsStatesAndReadsValueTypes()
    {
        TestDatabase.InsertRun(_writer, ("state", "RUNNING"), ("percent", 0.25));

        DatabaseRow row = Assert.Single(_database.Execute(
            "SELECT run_id, percent, label, x'0102' AS bytes FROM runs WHERE state = ?",
            SimulationState.Running));

        Assert.IsType<long>(row["run_id"]);
        Assert.Equal(0.25, row["percent"]);
        Assert.Null(row["label"]);
        Assert.Equal(new byte[] { 1, 2 }, row["bytes"]);
    }

    /// <summary>Refuse several statements, mismatched parameters, and unsupported parameter types.</summary>
    [Fact]
    public void ExecuteRejectsInvalidInput()
    {
        Assert.Throws<ArgumentException>(() => _database.Execute("SELECT 1; SELECT 2"));
        Assert.Throws<ArgumentException>(() => _database.Execute("SELECT ?"));
        Assert.Throws<ArgumentException>(() => _database.Execute("SELECT ?", new object()));
        Assert.Single(_database.Execute("SELECT 1; -- a trailing comment"));
    }

    /// <summary>Serialize calls from several threads on one database.</summary>
    [Fact]
    public void ConcurrentReadsAreSafe()
    {
        long runId = TestDatabase.InsertRun(_writer);

        Parallel.For(0, 200, _ => Assert.NotNull(_database.GetRun(runId)));
    }
}
