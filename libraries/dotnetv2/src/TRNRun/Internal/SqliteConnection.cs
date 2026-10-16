using System.Runtime.InteropServices;
using System.Text;
using TRNRun.Interop;

namespace TRNRun.Internal;

/// <summary>A SQLite connection that runs one statement at a time and returns its rows.</summary>
/// <remarks>Not thread-safe; <see cref="Database"/> serializes its calls.</remarks>
internal sealed unsafe class SqliteConnection : IDisposable
{
    /// <summary>Milliseconds a read waits for a lock, as Python's <c>sqlite3.connect</c> does by default.</summary>
    private const int BusyTimeoutMilliseconds = 5000;

    private readonly SqliteHandle _handle;

    /// <summary>Wraps an opened handle.</summary>
    private SqliteConnection(SqliteHandle handle)
    {
        _handle = handle;
    }

    /// <summary>Opens a database: read-only, or read-write and created if missing.</summary>
    /// <exception cref="DatabaseException">SQLite cannot open it, such as a missing file opened read-only.</exception>
    internal static SqliteConnection Open(string path, bool readOnly)
    {
        int flags = SqliteNative.OpenExtendedResultCodes
            | (readOnly ? SqliteNative.OpenReadOnly : SqliteNative.OpenReadWrite | SqliteNative.OpenCreate);
        int code = SqliteNative.Open(path, out SqliteHandle handle, flags, 0);
        if (code != SqliteNative.Ok)
        {
            // SQLite returns a handle even on failure, holding the message; it must still be closed.
            var error = handle.IsInvalid
                ? new DatabaseException($"Cannot open {path}", code)
                : new DatabaseException($"{LastError(handle)}: {path}", code);
            handle.Dispose();
            throw error;
        }

        _ = SqliteNative.BusyTimeout(handle, BusyTimeoutMilliseconds);
        return new SqliteConnection(handle);
    }

    /// <summary>The row ID of the latest successful INSERT on this connection.</summary>
    internal long LastInsertRowId => SqliteNative.LastInsertRowId(_handle);

    /// <summary>Runs one statement with positional <c>?</c> parameters and returns every row it produces.</summary>
    /// <exception cref="ArgumentException">The SQL holds more than one statement, or a parameter has an unsupported type.</exception>
    /// <exception cref="DatabaseException">SQLite rejects or fails the statement.</exception>
    internal List<DatabaseRow> Query(string sql, IReadOnlyList<object?>? parameters = null)
    {
        ObjectDisposedException.ThrowIf(_handle.IsClosed, this);
        nint statement = PrepareSingle(sql);
        try
        {
            var rows = new List<DatabaseRow>();
            if (statement == 0)
            {
                return rows; // Only whitespace or comments.
            }

            Bind(statement, parameters ?? []);
            Dictionary<string, int>? columns = null;
            int code;
            while ((code = SqliteNative.Step(statement)) == SqliteNative.Row)
            {
                columns ??= ColumnIndex(statement);
                var values = new object?[SqliteNative.ColumnCount(statement)];
                for (int index = 0; index < values.Length; index++)
                {
                    values[index] = ColumnValue(statement, index);
                }

                rows.Add(new DatabaseRow(columns, values));
            }

            if (code != SqliteNative.Done)
            {
                throw Error();
            }

            return rows;
        }
        finally
        {
            _ = SqliteNative.Finalize(statement);
        }
    }

    /// <summary>Runs one statement and discards its rows.</summary>
    internal void Execute(string sql, IReadOnlyList<object?>? parameters = null) => _ = Query(sql, parameters);

    /// <summary>Closes the connection. Safe to call more than once.</summary>
    public void Dispose() => _handle.Dispose();

    /// <summary>Prepares the only statement in <paramref name="sql"/>; 0 if it holds none.</summary>
    private nint PrepareSingle(string sql)
    {
        byte[] utf8 = Encoding.UTF8.GetBytes(sql);
        fixed (byte* start = utf8)
        {
            byte* end = start + utf8.Length;
            nint statement = 0;
            byte* next = start;
            while (next < end)
            {
                if (SqliteNative.Prepare(_handle, next, (int)(end - next), out nint prepared, out byte* tail) != SqliteNative.Ok)
                {
                    DatabaseException error = Error();
                    _ = SqliteNative.Finalize(statement);
                    throw error;
                }

                next = tail;
                if (prepared == 0)
                {
                    continue; // An empty statement, such as a trailing comment.
                }

                if (statement != 0)
                {
                    _ = SqliteNative.Finalize(prepared);
                    _ = SqliteNative.Finalize(statement);
                    throw new ArgumentException("Only one SQL statement can run at a time.", nameof(sql));
                }

                statement = prepared;
            }

            return statement;
        }
    }

    /// <summary>Binds every parameter, in order, checking that the statement expects that many.</summary>
    private void Bind(nint statement, IReadOnlyList<object?> parameters)
    {
        int expected = SqliteNative.BindParameterCount(statement);
        if (expected != parameters.Count)
        {
            throw new ArgumentException(
                $"The statement uses {expected} parameter(s), but {parameters.Count} were supplied.",
                nameof(parameters));
        }

        for (int index = 0; index < parameters.Count; index++)
        {
            if (BindValue(statement, index + 1, parameters[index]) != SqliteNative.Ok)
            {
                throw Error();
            }
        }
    }

    /// <summary>Binds one value as the SQLite type closest to its .NET type.</summary>
    private static int BindValue(nint statement, int position, object? value)
    {
        switch (value)
        {
            case null or DBNull:
                return SqliteNative.BindNull(statement, position);
            case string text:
                byte[] utf8 = Encoding.UTF8.GetBytes(text);
                fixed (byte* bytes = utf8)
                {
                    return SqliteNative.BindText(statement, position, bytes, utf8.Length, SqliteNative.Transient);
                }
            case byte[] blob:
                fixed (byte* bytes = blob)
                {
                    return SqliteNative.BindBlob(statement, position, bytes, blob.Length, SqliteNative.Transient);
                }
            case bool flag:
                return SqliteNative.BindInt64(statement, position, flag ? 1 : 0);
            case sbyte or byte or short or ushort or int or uint or long:
                return SqliteNative.BindInt64(statement, position, Convert.ToInt64(value, System.Globalization.CultureInfo.InvariantCulture));
            case float or double or decimal:
                return SqliteNative.BindDouble(statement, position, Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture));
            case SimulationState state:
                return BindValue(statement, position, RowParser.StateName(state));
            default:
                throw new ArgumentException(
                    $"Unsupported SQL parameter type {value.GetType().Name} at position {position}.",
                    "parameters");
        }
    }

    /// <summary>Maps each result column name, case-insensitively as SQLite does, to its first position.</summary>
    private static Dictionary<string, int> ColumnIndex(nint statement)
    {
        int count = SqliteNative.ColumnCount(statement);
        var columns = new Dictionary<string, int>(count, StringComparer.OrdinalIgnoreCase);
        for (int index = 0; index < count; index++)
        {
            string name = Marshal.PtrToStringUTF8((nint)SqliteNative.ColumnName(statement, index)) ?? "";
            _ = columns.TryAdd(name, index);
        }

        return columns;
    }

    /// <summary>Reads one column of the current row as a long, double, string, byte array or null.</summary>
    private static object? ColumnValue(nint statement, int index)
    {
        switch (SqliteNative.ColumnType(statement, index))
        {
            case SqliteNative.Integer:
                return SqliteNative.ColumnInt64(statement, index);
            case SqliteNative.Float:
                return SqliteNative.ColumnDouble(statement, index);
            case SqliteNative.Text:
                byte* text = SqliteNative.ColumnText(statement, index);
                return Encoding.UTF8.GetString(text, SqliteNative.ColumnBytes(statement, index));
            case SqliteNative.Blob:
                byte* blob = SqliteNative.ColumnBlob(statement, index);
                return new ReadOnlySpan<byte>(blob, SqliteNative.ColumnBytes(statement, index)).ToArray();
            default:
                return null;
        }
    }

    /// <summary>Describes the connection's latest error.</summary>
    private DatabaseException Error() =>
        new(LastError(_handle), SqliteNative.ExtendedErrorCode(_handle));

    /// <summary>Returns SQLite's message for a connection's latest error.</summary>
    private static string LastError(SqliteHandle handle) =>
        Marshal.PtrToStringUTF8((nint)SqliteNative.ErrorMessage(handle)) ?? "SQLite error";
}
