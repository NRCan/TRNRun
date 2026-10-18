using System.Data;
using System.Globalization;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;
using Microsoft.Data.Sqlite;

namespace TRNRun;

/// <summary>Opens a trnrund database read-only, with or without a daemon, and reads its rows as typed records.</summary>
/// <remarks>
/// The connections are Microsoft.Data.Sqlite's, so any other question about the runs is plain
/// SQL on the <c>runs</c> and <c>logs</c> tables. The extension methods here read their rows:
/// <c>connection.ReadChanges(position)</c>, <c>reader.GetSimulationInfo()</c> and
/// <c>reader.GetLogEvent()</c>.
/// </remarks>
public static class TrnrunDatabase
{
    /// <summary>The trnrund schema version this package reads.</summary>
    public const int SchemaVersion = 3;

    // -----------------------------------------------------------------
    // Reading
    // -----------------------------------------------------------------

    /// <summary>Opens an existing trnrund database read-only; a relative path resolves from the current working directory.</summary>
    /// <remarks>
    /// Connection pooling is off, so disposing the connection releases the file. Open it while
    /// trnrund runs: right after trnrund is killed, a new connection can fail with
    /// <c>disk I/O error</c>, while an open one keeps reading.
    /// </remarks>
    /// <exception cref="SqliteException">The database cannot be opened, such as when it does not exist.</exception>
    /// <exception cref="SchemaVersionException">Its schema version is not <see cref="SchemaVersion"/>; it is closed first.</exception>
    public static SqliteConnection Open(string path)
    {
        var builder = new SqliteConnectionStringBuilder
        {
            DataSource = Path.GetFullPath(path),
            Mode = SqliteOpenMode.ReadOnly,
            Pooling = false,
        };
        var connection = new SqliteConnection(builder.ToString());
        try
        {
            connection.Open();
            CheckSchema(connection);
        }
        catch
        {
            connection.Dispose();
            throw;
        }

        return connection;
    }

    /// <summary>Throws unless the database has the schema this package reads.</summary>
    private static void CheckSchema(SqliteConnection connection)
    {
        using SqliteCommand command = connection.CreateCommand();
        command.CommandText = "PRAGMA user_version";
        long version = (long)command.ExecuteScalar()!;
        if (version != SchemaVersion)
        {
            throw new SchemaVersionException($"Unsupported TRNRun database schema {version}; expected {SchemaVersion}");
        }
    }

    /// <summary>Returns the runs and logs saved after <paramref name="after"/>, read in one transaction.</summary>
    /// <param name="connection">An open connection to a trnrund database.</param>
    /// <param name="after">Where the previous read stopped; the default reads the whole history.</param>
    /// <remarks>Pass the returned <see cref="Changes.Next"/> to the next call. Call it outside any transaction of your own.</remarks>
    /// <exception cref="InvalidDataException">A row holds a value this package does not know.</exception>
    public static Changes ReadChanges(this SqliteConnection connection, ChangePosition after = default)
    {
        ArgumentNullException.ThrowIfNull(connection);
        var runs = new List<SimulationInfo>();
        var logs = new List<LogEvent>();
        // Deferred, so it only reads; Microsoft.Data.Sqlite otherwise begins IMMEDIATE, which writes.
        using (SqliteTransaction transaction = connection.BeginTransaction(deferred: true))
        {
            Read(transaction, "SELECT * FROM runs WHERE revision > $after ORDER BY revision", after.Revision, row => runs.Add(row.GetSimulationInfo()));
            Read(transaction, "SELECT * FROM logs WHERE log_id > $after ORDER BY log_id", after.LogId, row => logs.Add(row.GetLogEvent()));
            transaction.Commit();
        }

        var next = new ChangePosition(
            runs.Count > 0 ? runs[^1].Revision : after.Revision,
            logs.Count > 0 ? logs[^1].LogId : after.LogId);
        return new Changes(runs, logs, next);
    }

    /// <summary>Runs a query with one <c>$after</c> parameter, handing each row to <paramref name="parse"/>.</summary>
    private static void Read(SqliteTransaction transaction, string sql, long after, Action<IDataRecord> parse)
    {
        using SqliteCommand command = transaction.Connection!.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = sql;
        command.Parameters.AddWithValue("$after", after);
        using SqliteDataReader reader = command.ExecuteReader();
        while (reader.Read())
        {
            parse(reader);
        }
    }

    // -----------------------------------------------------------------
    // Row Parsers
    // -----------------------------------------------------------------

    /// <summary>Reads the current row of a <c>SELECT *</c> on <c>runs</c>; an event TRNRun has not reported yet becomes <see langword="null"/>.</summary>
    /// <exception cref="InvalidDataException">The row holds a value this package does not know, such as a newer state.</exception>
    public static SimulationInfo GetSimulationInfo(this IDataRecord row)
    {
        ArgumentNullException.ThrowIfNull(row);
        long runId = Required(Int64(row, "run_id"), "run_id");
        string? status = Text(row, "trnrun_status");
        double? percent = Double(row, "percent");
        double? stop = Double(row, "stop_time");
        string? setting = Text(row, "setting");
        return new SimulationInfo
        {
            RunId = runId,
            State = ParseState(Required(Text(row, "state"), "state")),
            DeckFile = Required(Text(row, "deck_file"), "deck_file"),
            SessionId = Required(Int64(row, "session_id"), "session_id"),
            Label = Text(row, "label"),
            Revision = Required(Int64(row, "revision"), "revision"),
            TrnrunArgs = ParseJson(Required(Text(row, "trnrun_args"), "trnrun_args"), RecordJsonContext.Default.StringArray, runId),
            Status = status is null ? null : ParseStatus(status),
            StatusMessage = Text(row, "trnrun_message"),
            Progress = percent is null
                ? null
                : new ProgressEvent(
                    Required(Double(row, "sim_time"), "sim_time"),
                    percent.Value,
                    Required(Double(row, "elapsed_ms"), "elapsed_ms"),
                    Required(Double(row, "eta_ms"), "eta_ms")),
            Config = stop is null
                ? null
                : new ConfigEvent(Required(Double(row, "start_time"), "start_time"), stop.Value, Required(Double(row, "time_step"), "time_step")),
            Setting = setting is null ? null : ParseJson(setting, RecordJsonContext.Default.DictionaryStringJsonElement, runId),
            Notices = (int)Required(Int64(row, "notices"), "notices"),
            Warnings = (int)Required(Int64(row, "warnings"), "warnings"),
            Fatals = (int)Required(Int64(row, "fatals"), "fatals"),
            Succeeded = Int64(row, "succeeded") is { } succeeded ? succeeded != 0 : null,
            ExitCode = Int64(row, "exit_code") is { } exitCode ? (int)exitCode : null,
            Error = Text(row, "error"),
            SubmittedAt = ParseTimestamp(Text(row, "submitted_at")),
            StartedAt = ParseTimestamp(Text(row, "started_at")),
            FinishedAt = ParseTimestamp(Text(row, "finished_at")),
        };
    }

    /// <summary>Reads the current row of a <c>SELECT *</c> on <c>logs</c>.</summary>
    /// <exception cref="InvalidDataException">The row holds a severity this package does not know.</exception>
    public static LogEvent GetLogEvent(this IDataRecord row)
    {
        ArgumentNullException.ThrowIfNull(row);
        return new LogEvent(
            LogId: Required(Int64(row, "log_id"), "log_id"),
            RunId: Required(Int64(row, "run_id"), "run_id"),
            Severity: ParseSeverity(Required(Text(row, "severity"), "severity")),
            Time: Required(Double(row, "sim_time"), "sim_time"),
            UnitId: Int64(row, "unit_id"),
            TypeId: Int64(row, "type_id"),
            MessageCode: Int64(row, "message_code"),
            Message: Text(row, "message"),
            Information: Text(row, "information"));
    }

    /// <summary>Returns the name trnrund saves for a state, such as <c>QUEUED</c>, to compare with the <c>state</c> column.</summary>
    public static string ToDatabaseName(this SimulationState state) => state switch
    {
        SimulationState.Queued => "QUEUED",
        SimulationState.Running => "RUNNING",
        SimulationState.Finished => "FINISHED",
        _ => throw new ArgumentOutOfRangeException(nameof(state), state, "Unknown simulation state."),
    };

    /// <summary>Parses a saved state name.</summary>
    private static SimulationState ParseState(string name) => name switch
    {
        "QUEUED" => SimulationState.Queued,
        "RUNNING" => SimulationState.Running,
        "FINISHED" => SimulationState.Finished,
        _ => throw new InvalidDataException($"Unknown run state '{name}'."),
    };

    /// <summary>Parses a STATUS name as TRNRun writes it, such as <c>DONE</c>.</summary>
    private static SimulationStatus ParseStatus(string name) => name switch
    {
        "PENDING" => SimulationStatus.Pending,
        "LAUNCHING" => SimulationStatus.Launching,
        "RUNNING" => SimulationStatus.Running,
        "DONE" => SimulationStatus.Done,
        "CANCELLED" => SimulationStatus.Cancelled,
        "ERROR" => SimulationStatus.Error,
        "TIMEOUT" => SimulationStatus.Timeout,
        "STALLED" => SimulationStatus.Stalled,
        _ => throw new InvalidDataException($"Unknown TRNRun status '{name}'."),
    };

    /// <summary>Parses a log severity as TRNSYS writes it, such as <c>Warning</c>.</summary>
    private static LogSeverity ParseSeverity(string name) => name switch
    {
        "Notice" => LogSeverity.Notice,
        "Warning" => LogSeverity.Warning,
        "Fatal" => LogSeverity.Fatal,
        _ => throw new InvalidDataException($"Unknown log severity '{name}'."),
    };

    /// <summary>Parses a saved UTC timestamp, such as <c>2026-10-09T14:03:12.345Z</c>.</summary>
    private static DateTimeOffset? ParseTimestamp(string? value) =>
        value is null
            ? null
            : DateTimeOffset.Parse(value, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal);

    /// <summary>Parses a saved JSON column of run <paramref name="runId"/>.</summary>
    private static T ParseJson<T>(string text, JsonTypeInfo<T> type, long runId)
        where T : class
    {
        try
        {
            return JsonSerializer.Deserialize(text, type) ?? throw new InvalidDataException($"Run {runId} has null JSON: {text}");
        }
        catch (JsonException error)
        {
            throw new InvalidDataException($"Unreadable JSON in run {runId}: {error.Message}", error);
        }
    }

    /// <summary>Returns an integer column, or <see langword="null"/> for NULL.</summary>
    private static long? Int64(IDataRecord row, string column)
    {
        int index = row.GetOrdinal(column);
        return row.IsDBNull(index) ? null : row.GetInt64(index);
    }

    /// <summary>Returns a numeric column as a double, or <see langword="null"/> for NULL.</summary>
    private static double? Double(IDataRecord row, string column)
    {
        int index = row.GetOrdinal(column);
        return row.IsDBNull(index) ? null : row.GetDouble(index);
    }

    /// <summary>Returns a text column, or <see langword="null"/> for NULL.</summary>
    private static string? Text(IDataRecord row, string column)
    {
        int index = row.GetOrdinal(column);
        return row.IsDBNull(index) ? null : row.GetString(index);
    }

    /// <summary>Returns a column that trnrund never leaves NULL.</summary>
    private static T Required<T>(T? value, string column)
        where T : struct =>
        value ?? throw new InvalidDataException($"Column '{column}' is unexpectedly NULL.");

    /// <summary>Returns a text column that trnrund never leaves NULL.</summary>
    private static string Required(string? value, string column) =>
        value ?? throw new InvalidDataException($"Column '{column}' is unexpectedly NULL.");
}

/// <summary>Reads saved JSON without reflection, keeping the library trim- and AOT-safe.</summary>
[JsonSerializable(typeof(string[]))]
[JsonSerializable(typeof(Dictionary<string, JsonElement>))]
internal sealed partial class RecordJsonContext : JsonSerializerContext;
