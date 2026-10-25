// Example: running one simulation and following it until it finishes, without blocking.
//
// Usage: TRNRun.Example <deck.dck> <TrnEXE64.exe> [--progress]
// --progress streams Type3830 progress, so it requires Type3830 in the deck.
// Ctrl+C stops waiting and interrupts the run.

using System.Globalization;
using TRNRun;

if (args.Length is < 2 or > 3 || (args.Length == 3 && args[2] != "--progress"))
{
    Console.Error.WriteLine("Usage: TRNRun.Example <deck.dck> <TrnEXE64.exe> [--progress]");
    Console.Error.WriteLine("--progress requires Type3830 in the deck.");
    return 2;
}

using var cancel = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true; // Let disposal interrupt the run rather than kill this process.
    cancel.Cancel();
};

var settings = new SimulationSettings { TrnexePath = args[1], WatchTmp = args.Length == 3 };

// Disposal interrupts unfinished runs; wait for this one inside the block.
await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 1, cancellationToken: cancel.Token);
long simId = await daemon.AddAsync(args[0], settings, cancellationToken: cancel.Token);

// TRNRunDaemon.WaitForFinishedAsync is enough without output; this loop also prints progress and logs as they arrive.
Simulation sim;
int printedLogs = 0;
double? printedPercent = null;
try
{
    while (true)
    {
        sim = await daemon.GetSimulationAsync(simId, withLogs: true, cancel.Token);
        if (sim.Percent is { } percent && percent != printedPercent)
        {
            Console.WriteLine(string.Create(CultureInfo.InvariantCulture, $"{percent:P0} at {sim.SimTime} h"));
            printedPercent = percent;
        }

        foreach (LogEvent log in sim.Logs.Skip(printedLogs).Where(log => log.Severity != LogSeverity.Notice))
        {
            Console.WriteLine($"{log.Severity} at {log.Time} h: {log.Message}");
        }

        printedLogs = sim.Logs.Count;
        if (sim.State == SimulationState.Finished)
        {
            break;
        }

        await Task.Delay(TimeSpan.FromMilliseconds(500), cancel.Token);
    }
}
catch (OperationCanceledException)
{
    Console.WriteLine("Cancelled; interrupting the run.");
    return 1;
}
catch (DaemonExitedException error)
{
    Console.Error.WriteLine($"trnrund stopped before the run finished: {error.Message}");
    return 1;
}

Console.WriteLine($"Deck: {sim.DeckFile}");
Console.WriteLine($"Status: {sim.Status?.ToString() ?? "none"} {sim.StatusMessage}");
Console.WriteLine($"Succeeded: {sim.Succeeded}; exit code: {sim.ExitCode}; error: {sim.Error}");
Console.WriteLine($"Logs: {sim.Notices} notices, {sim.Warnings} warnings, {sim.Fatals} fatals");
return sim.Succeeded == true ? 0 : 1;
