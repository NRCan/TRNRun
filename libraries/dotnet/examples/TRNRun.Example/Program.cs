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

var manager = new SimulationManager(
    maxConcurrent: 1,
    refreshInterval: TimeSpan.FromSeconds(1))
{
    ShowProgress = showProgress
};

try
{
    Simulation simulation = manager.Add(Path.GetFullPath(args[0]), config);
    Console.WriteLine($"Accepted {simulation.Id}: {simulation.IsAccepted}");
    Console.WriteLine($"Deck: {simulation.DeckPath}");
    Console.WriteLine($"TRNSYS: {simulation.Config.TrnExePath}");

    manager.Wait(simulation);

    Console.WriteLine($"Status: {simulation.Status}");
    Console.WriteLine($"Finished: {simulation.IsFinished}; succeeded: {simulation.Succeeded}");
    Console.WriteLine($"Progress: {simulation.Progress}");
    foreach (var log in simulation.Logs)
    {
        Console.WriteLine(log);
    }

    return simulation.Succeeded ? 0 : 1;
}
finally
{
    manager.Shutdown();
}
