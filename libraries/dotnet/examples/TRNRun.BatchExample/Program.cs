// Example: running copies of the example deck and reporting each one as it finishes.
//
// Usage: TRNRun.BatchExample [workers] [TrnEXE64.exe]
// workers defaults to 4; TrnEXE64.exe defaults to TRNRun's, C:\TRNSYS18\Exe\TrnEXE64.exe.

using TRNRun;

int workers = 4;
if (args.Length > 2 || (args.Length >= 1 && (!int.TryParse(args[0], out workers) || workers < 1)))
{
    Console.Error.WriteLine("Usage: TRNRun.BatchExample [workers] [TrnEXE64.exe]");
    return 2;
}

// One copy per run: TRNSYS writes its outputs beside the deck, under its name, so concurrent runs need distinct decks.
string master = Path.Combine(AppContext.BaseDirectory, "dck", "example_wo_plot_w_tracking.dck");
string runs = Directory.CreateDirectory(Path.Combine(AppContext.BaseDirectory, "runs")).FullName;
string[] decks = Enumerable.Range(1, 10)
    .Select(i => Path.Combine(runs, $"{Path.GetFileNameWithoutExtension(master)}_{i:000}.dck"))
    .ToArray();
foreach (string deck in decks)
{
    File.Copy(master, deck, overwrite: true);
}

var settings = new SimulationSettings { TrnexePath = args.ElementAtOrDefault(1) };

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
