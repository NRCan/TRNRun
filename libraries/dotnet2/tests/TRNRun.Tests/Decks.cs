using System.Text.Json.Nodes;

namespace TRNRun.Tests;

// The tests run the bundled trnrund.exe with TRNRun.FakeTrnrun as its runner. trnrund starts the
// runner as `<trnrun> <deck> <args...>`, so the fake reads the deck as a script: Decks.Write writes
// decks that print TRNRun's JSON events and exit with a chosen code.

/// <summary>A temporary directory of fake decks, deleted when disposed.</summary>
internal sealed class Decks : IDisposable
{
    /// <summary>The stand-in for TRNRun that replays a deck written by <see cref="Write"/>.</summary>
    internal static readonly string FakeTrnrun = Path.Combine(AppContext.BaseDirectory, "TRNRun.FakeTrnrun.exe");

    /// <summary>Events of a run that succeeds with one warning.</summary>
    internal static readonly JsonArray Done =
    [
        new JsonObject { ["kind"] = "STATUS", ["status"] = "RUNNING", ["message"] = "" },
        new JsonObject { ["kind"] = "CONFIG", ["start"] = 0, ["stop"] = 10, ["step"] = 1 },
        new JsonObject { ["kind"] = "LOG", ["severity"] = "Warning", ["time"] = 5, ["unitId"] = 7, ["typeId"] = 56, ["message"] = "careful" },
        new JsonObject { ["kind"] = "PROGRESS", ["time"] = 10, ["percent"] = 1, ["elapsedMs"] = 5, ["etaMs"] = 0 },
        new JsonObject { ["kind"] = "STATUS", ["status"] = "DONE", ["message"] = "" },
    ];

    private int _count;

    /// <summary>Absolute path of the directory.</summary>
    public string Directory { get; } = System.IO.Directory.CreateTempSubdirectory("trnrun-test-").FullName;

    /// <summary>Writes a deck that prints <paramref name="events"/>, <see cref="Done"/> by default, and exits with <paramref name="exitCode"/>; a gated one first holds for 30 s, for a test to cancel.</summary>
    public string Write(bool gated = false, JsonArray? events = null, int exitCode = 0)
    {
        string path = Path.Combine(Directory, $"deck{++_count}.dck");
        var script = new JsonObject { ["events"] = (events ?? Done).DeepClone(), ["exitCode"] = exitCode, ["gated"] = gated };
        File.WriteAllText(path, script.ToJsonString());
        return path;
    }

    /// <summary>Deletes the directory; a file still in use is left behind.</summary>
    public void Dispose()
    {
        try
        {
            System.IO.Directory.Delete(Directory, recursive: true);
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException)
        {
        }
    }
}
