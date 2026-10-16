using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;

namespace TRNRun.Interop;

/// <summary>The few SQLite functions this package reads with, from the winsqlite3.dll built into Windows 10 and later.</summary>
/// <remarks>trnrund writes its database with the same library, so there is no SQLite to ship.</remarks>
internal static unsafe partial class SqliteNative
{
    private const string Library = "winsqlite3";

    // Result codes.
    internal const int Ok = 0;
    internal const int Row = 100;
    internal const int Done = 101;

    // Open flags.
    internal const int OpenReadOnly = 0x00000001;
    internal const int OpenReadWrite = 0x00000002;
    internal const int OpenCreate = 0x00000004;
    internal const int OpenExtendedResultCodes = 0x02000000;

    // Fundamental datatypes.
    internal const int Integer = 1;
    internal const int Float = 2;
    internal const int Text = 3;
    internal const int Blob = 4;
    internal const int Null = 5;

    /// <summary>Tells SQLite to copy bound text and blobs before the call returns.</summary>
    internal static readonly nint Transient = -1;

    [LibraryImport(Library, EntryPoint = "sqlite3_open_v2", StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int Open(string filename, out SqliteHandle db, int flags, nint vfs);

    [LibraryImport(Library, EntryPoint = "sqlite3_close_v2")]
    internal static partial int Close(nint db);

    [LibraryImport(Library, EntryPoint = "sqlite3_extended_result_codes")]
    internal static partial int ExtendedResultCodes(SqliteHandle db, int onoff);

    [LibraryImport(Library, EntryPoint = "sqlite3_busy_timeout")]
    internal static partial int BusyTimeout(SqliteHandle db, int milliseconds);

    [LibraryImport(Library, EntryPoint = "sqlite3_errmsg")]
    internal static partial byte* ErrorMessage(SqliteHandle db);

    [LibraryImport(Library, EntryPoint = "sqlite3_extended_errcode")]
    internal static partial int ExtendedErrorCode(SqliteHandle db);

    [LibraryImport(Library, EntryPoint = "sqlite3_last_insert_rowid")]
    internal static partial long LastInsertRowId(SqliteHandle db);

    [LibraryImport(Library, EntryPoint = "sqlite3_prepare_v2")]
    internal static partial int Prepare(SqliteHandle db, byte* sql, int bytes, out nint statement, out byte* tail);

    [LibraryImport(Library, EntryPoint = "sqlite3_finalize")]
    internal static partial int Finalize(nint statement);

    [LibraryImport(Library, EntryPoint = "sqlite3_step")]
    internal static partial int Step(nint statement);

    [LibraryImport(Library, EntryPoint = "sqlite3_bind_parameter_count")]
    internal static partial int BindParameterCount(nint statement);

    [LibraryImport(Library, EntryPoint = "sqlite3_bind_null")]
    internal static partial int BindNull(nint statement, int index);

    [LibraryImport(Library, EntryPoint = "sqlite3_bind_int64")]
    internal static partial int BindInt64(nint statement, int index, long value);

    [LibraryImport(Library, EntryPoint = "sqlite3_bind_double")]
    internal static partial int BindDouble(nint statement, int index, double value);

    [LibraryImport(Library, EntryPoint = "sqlite3_bind_text")]
    internal static partial int BindText(nint statement, int index, byte* text, int bytes, nint destructor);

    [LibraryImport(Library, EntryPoint = "sqlite3_bind_blob")]
    internal static partial int BindBlob(nint statement, int index, byte* blob, int bytes, nint destructor);

    [LibraryImport(Library, EntryPoint = "sqlite3_column_count")]
    internal static partial int ColumnCount(nint statement);

    [LibraryImport(Library, EntryPoint = "sqlite3_column_name")]
    internal static partial byte* ColumnName(nint statement, int index);

    [LibraryImport(Library, EntryPoint = "sqlite3_column_type")]
    internal static partial int ColumnType(nint statement, int index);

    [LibraryImport(Library, EntryPoint = "sqlite3_column_int64")]
    internal static partial long ColumnInt64(nint statement, int index);

    [LibraryImport(Library, EntryPoint = "sqlite3_column_double")]
    internal static partial double ColumnDouble(nint statement, int index);

    [LibraryImport(Library, EntryPoint = "sqlite3_column_text")]
    internal static partial byte* ColumnText(nint statement, int index);

    [LibraryImport(Library, EntryPoint = "sqlite3_column_blob")]
    internal static partial byte* ColumnBlob(nint statement, int index);

    [LibraryImport(Library, EntryPoint = "sqlite3_column_bytes")]
    internal static partial int ColumnBytes(nint statement, int index);
}

/// <summary>An open SQLite connection, closed with <c>sqlite3_close_v2</c> when released.</summary>
internal sealed class SqliteHandle : SafeHandleZeroOrMinusOneIsInvalid
{
    /// <summary>Creates an empty handle for the marshaller to fill.</summary>
    public SqliteHandle() : base(ownsHandle: true)
    {
    }

    /// <summary>Closes the connection; statements still open are finalized with it.</summary>
    protected override bool ReleaseHandle() => SqliteNative.Close(handle) == SqliteNative.Ok;
}
