// Example: running the example deck and following it until it finishes, without blocking.
//
// Usage: TRNRun.Example [TrnEXE64.exe]
// TrnEXE64.exe defaults to TRNRun's, C:\TRNSYS18\Exe\TrnEXE64.exe.
// Ctrl+C stops waiting and interrupts the run.

using System.Globalization;
using TRNRun;

if (args.Length > 1)
{
    Console.Error.WriteLine("Usage: TRNRun.Example [TrnEXE64.exe]");
    return 2;
}

// Has Type3830, which WatchTmp needs to report progress.
string deck = Path.Combine(AppContext.BaseDirectory, "dck", "slow_wo_plot_w_tracking.dck");

using var cancel = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) =>
{
    e.Cancel = true; // Let disposal interrupt the run rather than kill this process.
    cancel.Cancel();
};

var settings = new SimulationSettings { TrnexePath = args.ElementAtOrDefault(0), WatchTmp = true };

// Disposal interrupts unfinished runs; wait for this one inside the block.
await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 1, cancellationToken: cancel.Token);
long simId = await daemon.AddAsync(deck, settings, cancellationToken: cancel.Token);

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
