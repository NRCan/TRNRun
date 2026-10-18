// A stand-in for trnrund that answers DaemonProcess requests by their cmd.
//
// Run as `TRNRun.FakeTrnrund [--ignore-eof] [args...]`. Each request line gets the reply its
// cmd names:
//
//   ready        ok, with the command-line args
//   reject       ok: false with an error
//   bare_reject  ok: false without an error
//   notify       a changed notification at revision, then ok
//   noise        lines a client must skip, then ok
//   mute         nothing; its reply comes before the next request's
//   crash        boom on stderr, then exit code 3, without replying
//   exit         ok, then exit with code, writing bye to stderr if not 0
//
// It exits 0 once stdin ends, unless --ignore-eof keeps it running until it is killed.

using System.Text.Json;
using System.Text.Json.Nodes;

var muted = new List<long>();
string? line;
while ((line = Console.In.ReadLine()) is not null)
{
    JsonObject request = JsonNode.Parse(line)!.AsObject();
    string cmd = (string)request["cmd"]!;
    long id = (long)request["id"]!;
    if (cmd == "mute")
    {
        muted.Add(id);
        continue;
    }

    foreach (long mutedId in muted)
    {
        Send(new JsonObject { ["id"] = mutedId, ["ok"] = true, ["late"] = true });
    }

    muted.Clear();
    var reply = new JsonObject { ["id"] = id, ["ok"] = true };
    switch (cmd)
    {
        case "ready":
            reply["args"] = new JsonArray(args.Select(arg => (JsonNode?)arg).ToArray());
            break;
        case "reject":
            reply = new JsonObject { ["id"] = id, ["ok"] = false, ["error"] = "Rejected on purpose" };
            break;
        case "bare_reject":
            reply = new JsonObject { ["id"] = id, ["ok"] = false };
            break;
        case "notify":
            Send(new JsonObject { ["event"] = "changed", ["revision"] = (long)request["revision"]! });
            break;
        case "noise":
            Console.Out.WriteLine("not json");
            Send(new JsonArray(1, 2, 3));
            Send(new JsonObject { ["something"] = "else" });
            Send(new JsonObject { ["event"] = "other" });
            break;
        case "crash":
            Console.Error.WriteLine("boom");
            return 3;
        case "exit":
            Send(reply);
            int code = request["code"] is { } value ? (int)value : 0;
            if (code != 0)
            {
                Console.Error.WriteLine("bye");
            }

            return code;
    }

    Send(reply);
}

if (args.Contains("--ignore-eof"))
{
    Thread.Sleep(TimeSpan.FromSeconds(60));
}

return 0;

// Writes one JSON line to stdout.
static void Send(JsonNode message)
{
    Console.Out.WriteLine(message.ToJsonString());
    Console.Out.Flush();
}
