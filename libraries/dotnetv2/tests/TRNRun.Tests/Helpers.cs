using System.Text;
using TRNRun.Internal;

namespace TRNRun.Tests;

// Shared test helpers: a trnrund-shaped database, fake TRNRun decks, and temporary directories.
//
// The daemon tests run the bundled trnrund.exe with TRNRun.FakeTrnrun as the TRNRun executable.
// trnrund starts TRNRun as `<trnrun> <deck> <args...>`, so the fake reads the deck as a script,
// and Decks.Write writes decks that print TRNRun's JSON events and exit with a chosen code.

/// <summary>Executables the tests start.</summary>
internal static class Executables
{
    /// <summary>The stand-in for trnrund that answers requests by their cmd.</summary>
    internal static readonly string FakeTrnrund = Path.Combine(AppContext.BaseDirectory, "TRNRun.FakeTrnrund.exe");

    /// <summary>The stand-in for TRNRun that replays a deck written by <see cref="Decks.Write"/>.</summary>
    internal static readonly string FakeTrnrun = Path.Combine(AppContext.BaseDirectory, "TRNRun.FakeTrnrun.exe");
}

/// <summary>A directory deleted, with its contents, when disposed.</summary>
internal sealed class TempDirectory : IDisposable
{
    /// <summary>Creates a new, empty directory.</summary>
    public TempDirectory()
    {
        Path = Directory.CreateTempSubdirectory("trnrun-test-").FullName;
    }

    /// <summary>Absolute path of the directory.</summary>
    public string Path { get; }

    /// <summary>Returns the absolute path of <paramref name="name"/> inside the directory.</summary>
    public string File(string name) => System.IO.Path.Combine(Path, name);

    /// <summary>Deletes the directory; a file still in use is left behind.</summary>
    public void Dispose()
    {
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }
}

/// <summary>Tests that change the process-wide working directory, so they run alone.</summary>
[CollectionDefinition(nameof(WorkingDirectoryCollection), DisableParallelization = true)]
public sealed class WorkingDirectoryCollection;

/// <summary>A database with trnrund's schema, written as trnrund would.</summary>
internal static class TestDatabase
{
    /// <summary>Mirrors <c>Schema</c> in components/trnrund/src/database.nim; keep both at the same version.</summary>
    private static readonly string[] Schema =
    [
        "CREATE TABLE sessions (session_id INTEGER PRIMARY KEY AUTOINCREMENT, started_at TEXT NOT NULL)",
        """
        CREATE TABLE runs (
          run_id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id INTEGER NOT NULL,
          label TEXT,
          revision INTEGER NOT NULL,
          state TEXT NOT NULL,
          trnrun_status TEXT,
          trnrun_message TEXT,
          percent REAL,
          sim_time REAL,
          elapsed_ms REAL,
          eta_ms REAL,
          notices INTEGER NOT NULL,
          warnings INTEGER NOT NULL,
          fatals INTEGER NOT NULL,
          succeeded INTEGER,
          exit_code INTEGER,
          error TEXT,
          submitted_at TEXT NOT NULL,
          started_at TEXT,
          finished_at TEXT,
          deck_file TEXT NOT NULL,
          trnrun_args TEXT NOT NULL,
          start_time REAL,
          stop_time REAL,
          time_step REAL,
          setting TEXT)
        """,
        "CREATE UNIQUE INDEX runs_revision ON runs (revision)",
        """
        CREATE TABLE logs (
          log_id INTEGER PRIMARY KEY,
          run_id INTEGER NOT NULL,
          severity TEXT NOT NULL,
          sim_time REAL NOT NULL,
          unit_id INTEGER,
          type_id INTEGER,
          message_code INTEGER,
          message TEXT,
          information TEXT)
        """,
    ];

    internal const string SubmittedAt = "2026-10-09T14:03:12.345Z";

    /// <summary>A saved SETTING event, as trnrund stores it: TRNRun's camelCase keys.</summary>
    internal static readonly IReadOnlyDictionary<string, object> Setting = new Dictionary<string, object>
    {
        ["trnexePath"] = @"C:\TRNSYS18\Exe\TrnEXE64.exe",
        ["guiVisibility"] = "hidden",
        ["waitForGui"] = true,
        ["waitForLst"] = true,
        ["waitForTmp"] = false,
        ["detectTimeoutMs"] = 300_000,
        ["extraDelayMs"] = 0,
        ["watchLog"] = true,
        ["watchTmp"] = false,
        ["watchTimeoutMs"] = 0,
        ["stallTimeoutMs"] = 0,
        ["pollMs"] = 100,
        ["cleanOnSuccess"] = false,
        ["killOnTimeout"] = false,
        ["killOnStall"] = false,
        ["severity"] = "Notice",
        ["writeEvents"] = false,
    };

    /// <summary>Returns <see cref="Setting"/> as JSON, with keys removed or added.</summary>
    internal static string SettingJson(string? without = null, (string Key, object Value)? with = null)
    {
        var setting = Setting.Where(pair => pair.Key != without).ToDictionary();
        if (with is { } extra)
        {
            setting[extra.Key] = extra.Value;
        }

        return System.Text.Json.JsonSerializer.Serialize(setting);
    }

    /// <summary>Creates a database with trnrund's schema and returns a writable connection to it.</summary>
    internal static SqliteConnection Create(string path, int version = Database.SchemaVersion)
    {
        SqliteConnection connection = SqliteConnection.Open(path, readOnly: false);
        foreach (string statement in Schema)
        {
            connection.Execute(statement);
        }

        connection.Execute($"PRAGMA user_version = {version}");
        return connection;
    }

    /// <summary>Opens a writable connection standing in for trnrund.</summary>
    internal static SqliteConnection OpenWriter(string path) => SqliteConnection.Open(path, readOnly: false);

    /// <summary>Saves a run, queued in session 1 unless <paramref name="columns"/> say otherwise, and returns its run_id.</summary>
    internal static long InsertRun(SqliteConnection connection, params (string Column, object? Value)[] columns)
    {
        var row = new Dictionary<string, object?>
        {
            ["session_id"] = 1,
            ["state"] = "QUEUED",
            ["notices"] = 0,
            ["warnings"] = 0,
            ["fatals"] = 0,
            ["submitted_at"] = SubmittedAt,
            ["deck_file"] = @"C:\decks\model.dck",
            ["trnrun_args"] = "[]",
            ["revision"] = NextRevision(connection),
        };
        foreach ((string column, object? value) in columns)
        {
            row[column] = value;
        }

        return Insert(connection, "runs", row);
    }

    /// <summary>Changes a run's columns and gives it the next revision, as trnrund does.</summary>
    internal static void UpdateRun(SqliteConnection connection, long runId, params (string Column, object? Value)[] columns)
    {
        var row = columns.ToDictionary(pair => pair.Column, pair => pair.Value);
        row["revision"] = NextRevision(connection);
        string assignments = string.Join(", ", row.Keys.Select(name => $"{name} = ?"));
        connection.Execute($"UPDATE runs SET {assignments} WHERE run_id = ?", [.. row.Values, runId]);
    }

    /// <summary>Saves a Notice log entry for <paramref name="runId"/> unless <paramref name="columns"/> say otherwise, and returns its log_id.</summary>
    internal static long InsertLog(SqliteConnection connection, long runId, params (string Column, object? Value)[] columns)
    {
        var row = new Dictionary<string, object?> { ["run_id"] = runId, ["severity"] = "Notice", ["sim_time"] = 0.0 };
        foreach ((string column, object? value) in columns)
        {
            row[column] = value;
        }

        return Insert(connection, "logs", row);
    }

    /// <summary>Returns one row of <paramref name="table"/> by its key column.</summary>
    internal static DatabaseRow FetchRow(SqliteConnection connection, string table, string key, long value) =>
        connection.Query($"SELECT * FROM {table} WHERE {key} = ?", [value])[0];

    /// <summary>Returns the revision trnrund would give the next save.</summary>
    private static long NextRevision(SqliteConnection connection) =>
        (long)connection.Query("SELECT coalesce(max(revision), 0) + 1 FROM runs")[0][0]!;

    /// <summary>Inserts one row and returns its row ID.</summary>
    private static long Insert(SqliteConnection connection, string table, Dictionary<string, object?> row)
    {
        string names = string.Join(", ", row.Keys);
        string marks = string.Join(", ", row.Keys.Select(_ => "?"));
        connection.Execute($"INSERT INTO {table} ({names}) VALUES ({marks})", [.. row.Values]);
        return connection.LastInsertRowId;
    }
}

/// <summary>Decks for <see cref="Executables.FakeTrnrun"/>.</summary>
internal static class Decks
{
    /// <summary>What a successful run prints: one log entry of each severity, then a DONE status.</summary>
    internal static readonly string[] DoneEvents =
    [
        """{"kind":"STATUS","status":"RUNNING","message":""}""",
        """{"kind":"CONFIG","start":0,"stop":10,"step":1}""",
        """{"kind":"LOG","severity":"Notice","time":0,"message":"first"}""",
        """{"kind":"LOG","severity":"Warning","time":5,"unitId":7,"typeId":56,"messageCode":123,"message":"second","information":"details"}""",
        """{"kind":"LOG","severity":"Fatal","time":10,"message":"third"}""",
        """{"kind":"PROGRESS","time":10,"percent":1,"elapsedMs":5,"etaMs":0}""",
        """{"kind":"STATUS","status":"DONE","message":""}""",
    ];

    /// <summary>What a failed run prints.</summary>
    internal static readonly string[] FailedEvents = ["""{"kind":"STATUS","status":"ERROR","message":"Fake failure"}"""];

    /// <summary>Writes a deck that prints <paramref name="events"/> as TRNRun would, then exits with <paramref name="exitCode"/>.</summary>
    /// <remarks>A gated deck first waits for <see cref="Release"/>, so a test can hold it running.</remarks>
    internal static string Write(string path, string[]? events = null, int exitCode = 0, bool gated = false)
    {
        var script = new StringBuilder();
        script.Append("{\"events\":[").AppendJoin(',', events ?? DoneEvents).Append("],");
        script.Append($"\"exitCode\":{exitCode},\"gated\":{(gated ? "true" : "false")}}}");
        File.WriteAllText(path, script.ToString());
        return path;
    }

    /// <summary>Lets a gated deck go on.</summary>
    internal static void Release(string deck) =>
        File.WriteAllText(Path.ChangeExtension(deck, ".release"), "");
}
