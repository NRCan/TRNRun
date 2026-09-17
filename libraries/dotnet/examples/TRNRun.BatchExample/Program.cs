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
var manager = new SimulationManager(maxConcurrent: maxConcurrent);

try
{
    foreach (string deck in decks)
    {
        Simulation simulation = manager.Add(deck, config);
        Console.WriteLine($"Accepted {simulation.Id}: {simulation.DeckPath}");
    }

    // Follow does not replay updates consumed while earlier Add calls were blocking.
    foreach (Simulation simulation in manager.Follow())
    {
        Console.WriteLine($"{simulation.Id}: {simulation.Status}; finished: {simulation.IsFinished}");
    }

    Console.WriteLine($"{manager.Succeeded.Count} succeeded, {manager.Failed.Count} failed");
    foreach (Simulation simulation in manager.Failed)
    {
        Console.Error.WriteLine($"Failed: {simulation.DeckPath} ({simulation.Status})");
        foreach (var log in simulation.Logs)
        {
            Console.Error.WriteLine(log);
        }
    }

    return manager.Failed.Count == 0 ? 0 : 1;
}
finally
{
    manager.Shutdown();
}
