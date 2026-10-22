using System.Text.Json;
using System.Text.Json.Serialization;

namespace TRNRun;

/// <summary>Reads saved JSON without reflection, keeping the library trim- and AOT-safe.</summary>
[JsonSerializable(typeof(string[]))]
[JsonSerializable(typeof(Dictionary<string, JsonElement>))]
internal sealed partial class RecordJsonContext : JsonSerializerContext;
