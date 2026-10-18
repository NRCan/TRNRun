using Microsoft.Data.Sqlite;

namespace TRNRun.Tests;

/// <summary>Tests for <see cref="TrnrunDatabase.Open"/> and <see cref="TrnrunDatabase.ReadChanges"/>: opening a trnrund database and reading its changes.</summary>
public sealed class TrnrunDatabaseTests : IDisposable
{
    private readonly TempDirectory _temp = new();
    private readonly SqliteConnection _writer;
    private readonly SqliteConnection _reader;

    /// <summary>Creates a database with trnrund's schema, a writer standing in for trnrund, and a reader.</summary>
    public TrnrunDatabaseTests()
    {
        _writer = TestDatabase.Create(_temp.File("runs.sqlite3"));
        _reader = TrnrunDatabase.Open(_temp.File("runs.sqlite3"));
    }

    /// <summary>Closes both connections and deletes the database.</summary>
    public void Dispose()
    {
        _reader.Dispose();
        _writer.Dispose();
        _temp.Dispose();
    }

    // -----------------------------------------------------------------
    // Open
    // -----------------------------------------------------------------

    /// <summary>Never create a database: trnrund owns it.</summary>
    [Fact]
    public void OpenMissingDatabaseFails()
    {
        string missing = _temp.File("missing.sqlite3");

        Assert.Throws<SqliteException>(() => TrnrunDatabase.Open(missing));
        Assert.False(File.Exists(missing));
    }

    /// <summary>Refuse a database this package cannot read, without leaving it open.</summary>
    [Fact]
    public void OpenRejectsAnotherSchemaVersionAndCloses()
    {
        string path = _temp.File("old.sqlite3");
        TestDatabase.Create(path, version: 2).Dispose();

        var error = Assert.Throws<SchemaVersionException>(() => TrnrunDatabase.Open(path));

        Assert.Equal("Unsupported TRNRun database schema 2; expected 3", error.Message);
        File.Delete(path); // Fails on Windows while a connection still holds the file.
    }

    /// <summary>Never let a reader write to trnrund's database.</summary>
    [Fact]
    public void ConnectionIsReadOnly()
    {
        var error = Assert.Throws<SqliteException>(
            () => TestDatabase.Execute(_reader, "INSERT INTO sessions (started_at) VALUES ('now')"));
        Assert.Contains("readonly", error.Message);
    }

    // -----------------------------------------------------------------
    // ReadChanges
    // -----------------------------------------------------------------

    /// <summary>Return the position to read after, so nothing is returned twice.</summary>
    [Fact]
    public void ReadChangesReturnsEverythingThenOnlyWhatIsNew()
    {
        long first = TestDatabase.InsertRun(_writer);
        long second = TestDatabase.InsertRun(_writer);
        long log = TestDatabase.InsertLog(_writer, first, ("message", "hello"));

        Changes changes = _reader.ReadChanges();

        Assert.Equal([first, second], changes.Runs.Select(info => info.RunId));
        Assert.Equal([log], changes.Logs.Select(entry => entry.LogId));
        Assert.Equal(new ChangePosition(2, log), changes.Next);
        Assert.True(_reader.ReadChanges(changes.Next).IsEmpty);

        TestDatabase.UpdateRun(_writer, first, ("state", "RUNNING"));
        long laterLog = TestDatabase.InsertLog(_writer, first, ("severity", "Warning"));

        Changes later = _reader.ReadChanges(changes.Next);

        Assert.Equal([(first, SimulationState.Running)], later.Runs.Select(info => (info.RunId, info.State)));
        Assert.Equal([laterLog], later.Logs.Select(entry => entry.LogId));
    }

    /// <summary>Return each run once, at its latest revision, ordered by when it last changed.</summary>
    [Fact]
    public void ReadChangesReturnsTheLatestSnapshotInChangeOrder()
    {
        long first = TestDatabase.InsertRun(_writer);
        long second = TestDatabase.InsertRun(_writer);
        TestDatabase.UpdateRun(_writer, first, ("state", "RUNNING"));
        TestDatabase.UpdateRun(_writer, first, ("state", "FINISHED"), ("trnrun_status", "DONE"), ("succeeded", 1), ("exit_code", 0));

        Changes changes = _reader.ReadChanges();

        Assert.Equal([second, first], changes.Runs.Select(info => info.RunId));
        Assert.Equal(SimulationState.Finished, changes.Runs[^1].State);
        Assert.Equal((4L, 4L), (changes.Runs[^1].Revision, changes.Next.Revision));
    }

    /// <summary>Skip the history up to the given position.</summary>
    [Fact]
    public void ReadChangesStartsAfterTheGivenPosition()
    {
        long old = TestDatabase.InsertRun(_writer);
        long oldLog = TestDatabase.InsertLog(_writer, old);
        long recent = TestDatabase.InsertRun(_writer);
        long recentLog = TestDatabase.InsertLog(_writer, recent);

        Changes changes = _reader.ReadChanges(new ChangePosition(1, oldLog));

        Assert.Equal([recent], changes.Runs.Select(info => info.RunId));
        Assert.Equal([recentLog], changes.Logs.Select(entry => entry.LogId));
    }

    /// <summary>Return the position read from, so the next read starts at the same place.</summary>
    [Fact]
    public void ReadChangesKeepsThePositionWhenNothingIsNew()
    {
        Changes changes = _reader.ReadChanges(new ChangePosition(7, 3));

        Assert.True(changes.IsEmpty);
        Assert.Equal(new ChangePosition(7, 3), changes.Next);
    }
}
