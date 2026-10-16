using System.Globalization;

namespace TRNRun;

/// <summary>One row returned by <see cref="Database.Execute"/>, readable by column name or position.</summary>
/// <remarks>
/// Values are SQLite's: <see cref="long"/> for integers, <see cref="double"/> for reals,
/// <see cref="string"/> for text, a <see cref="byte"/> array for blobs, and
/// <see langword="null"/> for NULL. Column names are matched case-insensitively, as SQLite does.
/// </remarks>
public sealed class DatabaseRow
{
    private readonly IReadOnlyDictionary<string, int> _columns;
    private readonly object?[] _values;

    /// <summary>Wraps one row's values and its statement's column positions, shared by every row.</summary>
    internal DatabaseRow(IReadOnlyDictionary<string, int> columns, object?[] values)
    {
        _columns = columns;
        _values = values;
    }

    /// <summary>Number of columns.</summary>
    public int Count => _values.Length;

    /// <summary>The value at a column position, from 0.</summary>
    public object? this[int index] => _values[index];

    /// <summary>The value of a named column.</summary>
    /// <exception cref="KeyNotFoundException">The row has no such column.</exception>
    public object? this[string column] => _values[IndexOf(column)];

    /// <summary>Returns an integer column, or <see langword="null"/> for NULL.</summary>
    /// <exception cref="InvalidCastException">The value is not an integer.</exception>
    public long? GetInt64(string column) => this[column] switch
    {
        null => null,
        long value => value,
        var other => throw WrongType(column, other, "an integer"),
    };

    /// <summary>Returns a numeric column as a double, or <see langword="null"/> for NULL.</summary>
    /// <exception cref="InvalidCastException">The value is not a number.</exception>
    public double? GetDouble(string column) => this[column] switch
    {
        null => null,
        double value => value,
        long value => value,
        var other => throw WrongType(column, other, "a number"),
    };

    /// <summary>Returns a text column, or <see langword="null"/> for NULL.</summary>
    /// <exception cref="InvalidCastException">The value is not text.</exception>
    public string? GetString(string column) => this[column] switch
    {
        null => null,
        string value => value,
        var other => throw WrongType(column, other, "text"),
    };

    /// <summary>Returns the position of a named column.</summary>
    private int IndexOf(string column) =>
        _columns.TryGetValue(column, out int index)
            ? index
            : throw new KeyNotFoundException($"No column named '{column}'.");

    /// <summary>Describes a value that is not the type asked for.</summary>
    private static InvalidCastException WrongType(string column, object value, string expected) =>
        new(string.Create(
            CultureInfo.InvariantCulture,
            $"Column '{column}' holds {value.GetType().Name} {value}, not {expected}."));
}
