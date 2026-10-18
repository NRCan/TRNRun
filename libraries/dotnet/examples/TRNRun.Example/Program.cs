// Example: running one simulation and following it until it finishes, without blocking.
//
// Usage: TRNRun.Example <deck.dck> <TrnEXE64.exe> [--progress]
// --progress streams Type3830 progress, so it requires Type3830 in the deck.
// Ctrl+C stops waiting and interrupts the run.

using System.Globalization;
using Microsoft.Data.Sqlite;
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

// Disposal interrupts unfinished runs; wait for this one inside the block. The connection is
// disposed first, before the daemon deletes its temporary database.
await using Daemon daemon = await Daemon.StartAsync(new DaemonOptions { MaxConcurrent = 1 }, cancel.Token);
using SqliteConnection connection = daemon.OpenDatabase();
long runId = await daemon.AddAsync(args[0], settings, cancellationToken: cancel.Token);

ChangePosition position = daemon.StartPosition;
SimulationInfo? finished = null;
try
{
    while (finished is null)
    {
        await daemon.WaitForChangesAsync(position.Revision, cancel.Token); // Throws if trnrund crashed.
        Changes changes = connection.ReadChanges(position);
        position = changes.Next;
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

        foreach (LogEvent log in changes.Logs.Where(log => log.Severity != LogSeverity.Notice))
        {
            Console.WriteLine($"{log.Severity} at {log.Time} h: {log.Message}");
        }
    }
}
catch (OperationCanceledException)
{
    Console.WriteLine("Cancelled; interrupting the run.");
    return 1;
}

Console.WriteLine($"Deck: {finished.DeckFile}");
Console.WriteLine($"Status: {finished.Status?.ToString() ?? "none"} {finished.StatusMessage}");
Console.WriteLine($"Succeeded: {finished.Succeeded}; exit code: {finished.ExitCode}; error: {finished.Error}");
Console.WriteLine($"Logs: {finished.Notices} notices, {finished.Warnings} warnings, {finished.Fatals} fatals");
return finished.Succeeded == true ? 0 : 1;
