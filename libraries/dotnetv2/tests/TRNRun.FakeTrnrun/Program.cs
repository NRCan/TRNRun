// A stand-in for TRNRun that replays a scripted deck.
//
// trnrund starts TRNRun as `<trnrun> <deck> <args...>`. The deck here is JSON written by the
// tests' Decks.Write: {"events": [...], "exitCode": 0, "gated": false}. The runner prints each
// event as one JSON line, as TRNRun would, then exits with exitCode. A gated deck first waits,
// up to 30 seconds, for a .release file beside it, so a test can hold the run.

using System.Text.Json;

string deck = args[0];
using JsonDocument script = JsonDocument.Parse(File.ReadAllText(deck));
JsonElement root = script.RootElement;

if (root.GetProperty("gated").GetBoolean())
{
    string release = Path.ChangeExtension(deck, ".release");
    DateTime deadline = DateTime.UtcNow.AddSeconds(30);
    while (!File.Exists(release) && DateTime.UtcNow < deadline)
    {
        Thread.Sleep(10);
    }
}

foreach (JsonElement runEvent in root.GetProperty("events").EnumerateArray())
{
    Console.Out.WriteLine(runEvent.GetRawText());
    Console.Out.Flush();
}

return root.GetProperty("exitCode").GetInt32();
