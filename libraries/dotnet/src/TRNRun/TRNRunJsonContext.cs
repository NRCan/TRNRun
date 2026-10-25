using System.Text.Json;
using System.Text.Json.Serialization;

namespace TRNRun;

/// <summary>Source-generated JSON reader for trnrund's simulation objects, so the library stays trim- and AOT-safe.</summary>
/// <remarks>trnrund sends enums uppercase, such as <c>RUNNING</c>; the string enum converter matches them case-insensitively.</remarks>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, UseStringEnumConverter = true)]
[JsonSerializable(typeof(Simulation))]
[JsonSerializable(typeof(Simulation[]))]
internal sealed partial class TRNRunJsonContext : JsonSerializerContext;

/// <summary>Converts trnrund's millisecond numbers, such as <c>elapsedMs</c>, to and from <see cref="TimeSpan"/>.</summary>
internal sealed class MillisecondsConverter : JsonConverter<TimeSpan>
{
    /// <inheritdoc/>
    public override TimeSpan Read(ref Utf8JsonReader reader, Type typeToConvert, JsonSerializerOptions options) =>
        TimeSpan.FromMilliseconds(reader.GetDouble());

    /// <inheritdoc/>
    public override void Write(Utf8JsonWriter writer, TimeSpan value, JsonSerializerOptions options) =>
        writer.WriteNumberValue(value.TotalMilliseconds);
}
