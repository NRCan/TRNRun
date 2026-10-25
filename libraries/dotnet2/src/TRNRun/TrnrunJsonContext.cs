using System.Text.Json.Serialization;

namespace TRNRun;

/// <summary>Reads trnrund's simulation objects without reflection; its enums arrive uppercase, which the enum converter reads case-insensitively.</summary>
[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, UseStringEnumConverter = true)]
[JsonSerializable(typeof(Simulation))]
[JsonSerializable(typeof(Simulation[]))]
internal sealed partial class TrnrunJsonContext : JsonSerializerContext;
