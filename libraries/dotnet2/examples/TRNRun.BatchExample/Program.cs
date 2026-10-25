// Example: running every deck in a directory and reporting each one as it finishes.
//
// Usage: TRNRun.BatchExample <deck-directory> <TrnEXE64.exe> [workers]
// workers defaults to 4.

using TRNRun;

int workers = 4;
if (args.Length is < 2 or > 3 || (args.Length == 3 && (!int.TryParse(args[2], out workers) || workers < 1)))
{
    Console.Error.WriteLine("Usage: TRNRun.BatchExample <deck-directory> <TrnEXE64.exe> [workers]");
    return 2;
}

string[] decks = Directory.GetFiles(args[0], "*.dck");
if (decks.Length == 0)
{
    Console.Error.WriteLine($"No .dck files in {Path.GetFullPath(args[0])}");
    return 2;
}

var settings = new SimulationSettings { TrnexePath = args[1] };

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers);
foreach (string deck in decks)
{
    await daemon.AddAsync(deck, settings, label: Path.GetFileNameWithoutExtension(deck));
}

Console.WriteLine($"Running {decks.Length} decks, {workers} at a time");

// Each finished run is released once reported, so every poll returns only the newly finished ones, logs included.
int finished = 0;
int failed = 0;
while (finished < decks.Length)
{
    await Task.Delay(TimeSpan.FromMilliseconds(500));
    foreach (Simulation sim in await daemon.GetSimulationsAsync(SimulationState.Finished, withLogs: true))
    {
        finished++;
        string outcome = sim.Succeeded == true ? "ok" : $"FAILED ({sim.Status}) {sim.Error}";
        Console.WriteLine($"[{finished}/{decks.Length}] {sim.Label}: {outcome}");
        if (sim.Succeeded != true)
        {
            failed++;
            foreach (LogEvent log in sim.Logs.Where(log => log.Severity == LogSeverity.Fatal))
            {
                Console.WriteLine($"  at {log.Time} h: {log.Message}");
            }
        }

        await daemon.ReleaseAsync(sim.SimId);
    }
}

Console.WriteLine($"{decks.Length - failed} succeeded, {failed} failed");
return failed == 0 ? 0 : 1;
