using TRNRun;

if (args.Length is < 2 or > 3 || (args.Length == 3 && args[2] != "--progress"))
{
    Console.Error.WriteLine("Usage: TRNRun.Example <deck.dck> <TrnEXE64.exe> [--progress]");
    Console.Error.WriteLine("--progress requires Type3830 in the deck.");
    return 2;
}

bool showProgress = args.Length == 3;
var config = new SimulationConfig
{
    TrnExePath = Path.GetFullPath(args[1]),
    WatchTmp = showProgress
};

using var manager = new SimulationManager(
    maxConcurrent: 1,
    refreshInterval: TimeSpan.FromSeconds(1))
{
    ShowProgress = showProgress
};

Simulation simulation = manager.Add(Path.GetFullPath(args[0]), config);
Console.WriteLine($"Accepted {simulation.Id}: {simulation.IsAccepted}");
Console.WriteLine($"Deck: {simulation.DeckPath}");
Console.WriteLine($"TRNSYS: {simulation.Config.TrnExePath}");

// Disposal terminates remaining work; wait for this run before leaving the scope.
manager.Wait(simulation);
SimulationSnapshot snapshot = simulation.Snapshot();

Console.WriteLine($"Status: {snapshot.Status}");
Console.WriteLine($"Finished: {snapshot.IsFinished}; succeeded: {snapshot.Succeeded}");
Console.WriteLine($"Progress: {snapshot.Progress}");
foreach (var log in simulation.Logs)
{
    Console.WriteLine(log);
}

return snapshot.Succeeded ? 0 : 1;
