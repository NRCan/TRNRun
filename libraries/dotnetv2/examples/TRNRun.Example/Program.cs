// Example: running one simulation and following it until it finishes.
//
// Usage: TRNRun.Example <deck.dck> <TrnEXE64.exe> [--progress]
// --progress streams Type3830 progress, so it requires Type3830 in the deck.

using System.Globalization;
using TRNRun;

if (args.Length is < 2 or > 3 || (args.Length == 3 && args[2] != "--progress"))
{
    Console.Error.WriteLine("Usage: TRNRun.Example <deck.dck> <TrnEXE64.exe> [--progress]");
    Console.Error.WriteLine("--progress requires Type3830 in the deck.");
    return 2;
}

var settings = new SimulationSettings { TrnexePath = args[1], WatchTmp = args.Length == 3 };

// Disposal interrupts unfinished runs; wait for this one inside the block.
using var daemon = new Daemon(maxConcurrent: 1);
long runId = daemon.Add(args[0], settings);

SimulationInfo? finished = null;
while (finished is null)
{
    Changes changes = daemon.Wait(); // Blocks until trnrund saves something; throws if it crashed.
    foreach (SimulationInfo run in changes.Runs.Where(run => run.RunId == runId))
    {
        if (run.Progress is { } progress)
        {
            Console.WriteLine(string.Create(CultureInfo.InvariantCulture, $"{progress.Percent:P0} at {progress.Time} h"));
        }

        if (run.IsFinished)
        {
            finished = run;
        }
    }

    foreach (LogEvent log in changes.Logs.Where(log => log.Severity != "Notice"))
    {
        Console.WriteLine($"{log.Severity} at {log.Time} h: {log.Message}");
    }
}

Console.WriteLine($"Deck: {finished.DeckFile}");
Console.WriteLine($"Status: {finished.Status?.Status.ToString() ?? "none"} {finished.Status?.Message}");
Console.WriteLine($"Succeeded: {finished.Succeeded}; exit code: {finished.ExitCode}; error: {finished.Error}");
Console.WriteLine($"Logs: {finished.Notices} notices, {finished.Warnings} warnings, {finished.Fatals} fatals");
return finished.Succeeded ? 0 : 1;
