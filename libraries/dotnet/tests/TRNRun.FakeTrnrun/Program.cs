// A stand-in for TRNRun that replays a scripted deck.
//
// trnrund starts TRNRun as `<trnrun> <deck> <args...>`. The deck here is JSON written by the
// tests' Decks.Write: {"events": [...], "exitCode": 0, "gated": false}. The runner prints each
// event as one JSON line, as TRNRun would, then exits with exitCode. A gated deck first holds
// for 30 seconds, so a test can cancel it while it runs.

using System.Text.Json;

using JsonDocument script = JsonDocument.Parse(File.ReadAllText(args[0]));
JsonElement root = script.RootElement;

if (root.GetProperty("gated").GetBoolean())
{
    Thread.Sleep(TimeSpan.FromSeconds(30));
}

foreach (JsonElement runEvent in root.GetProperty("events").EnumerateArray())
{
    Console.Out.WriteLine(runEvent.GetRawText());
    Console.Out.Flush();
}

return root.GetProperty("exitCode").GetInt32();
