using TRNRun;

int maxConcurrent = 4;
if (args.Length is < 2 or > 3 ||
    (args.Length == 3 && (!int.TryParse(args[2], out maxConcurrent) || maxConcurrent < 1)))
{
    Console.Error.WriteLine("Usage: TRNRun.BatchExample <deck-directory> <TrnEXE64.exe> [maxConcurrent]");
    return 2;
}

string directory = Path.GetFullPath(args[0]);
if (!Directory.Exists(directory))
{
    Console.Error.WriteLine($"Deck directory does not exist: {directory}");
    return 2;
}

string[] decks = Directory.GetFiles(directory, "*.dck")
    .OrderBy(path => path, StringComparer.OrdinalIgnoreCase)
    .ToArray();
if (decks.Length == 0)
{
    Console.Error.WriteLine($"No .dck files found in {directory}");
    return 2;
}

var config = new SimulationConfig
{
    TrnExePath = Path.GetFullPath(args[1])
};
using var manager = new SimulationManager(maxConcurrent: maxConcurrent);

foreach (string deck in decks)
{
    Simulation simulation = manager.Add(deck, config, blocking: false);
    Console.WriteLine($"Submitted {simulation.Id}: {simulation.DeckPath}");
}

// Submitted includes pending acceptance, in submission order.
var submitted = manager.Submitted;
Console.WriteLine($"Submitted {submitted.Count} simulations");

// Follow observes live state without replay; slow consumers may see coalesced updates.
// The queue reader continues even if this loop pauses or stops early.
foreach (Simulation simulation in manager.Follow())
{
    SimulationSnapshot snapshot = simulation.Snapshot();
    Console.WriteLine($"{snapshot.Id}: {snapshot.Status}; accepted: {snapshot.IsAccepted}; finished: {snapshot.IsFinished}");
}

// Wait covers all submitted runs, including pending acceptance, before disposal.
manager.Wait();
foreach (Simulation simulation in submitted)
{
    SimulationSnapshot snapshot = simulation.Snapshot();
    Console.WriteLine($"Final {snapshot.Id}: {snapshot.Status}; succeeded: {snapshot.Succeeded}");
    if (!snapshot.Succeeded)
    {
        Console.Error.WriteLine($"Failed: {snapshot.DeckPath} ({snapshot.Status})");
        foreach (var log in simulation.Logs)
        {
            Console.Error.WriteLine(log);
        }
    }
}

Console.WriteLine($"{manager.Succeeded.Count} succeeded, {manager.Failed.Count} failed");
return manager.Failed.Count == 0 ? 0 : 1;
