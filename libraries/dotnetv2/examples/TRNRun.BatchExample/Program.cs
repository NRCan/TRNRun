// Example: running every deck in a directory and keeping the results in a database.
//
// Usage: TRNRun.BatchExample <deck-directory> <TrnEXE64.exe> [maxConcurrent] [database.sqlite3]
// maxConcurrent defaults to 4; the database defaults to runs.sqlite3 in the deck directory.
// A reused database keeps its earlier runs; this batch is its own session.

using TRNRun;

if (args.Length is < 2 or > 4 || (args.Length >= 3 && !int.TryParse(args[2], out _)))
{
    Console.Error.WriteLine("Usage: TRNRun.BatchExample <deck-directory> <TrnEXE64.exe> [maxConcurrent] [database.sqlite3]");
    return 2;
}

string[] decks = Directory.GetFiles(args[0], "*.dck");
if (decks.Length == 0)
{
    Console.Error.WriteLine($"No .dck files in {Path.GetFullPath(args[0])}");
    return 2;
}

int maxConcurrent = args.Length >= 3 ? int.Parse(args[2]) : 4;
string databasePath = args.Length == 4 ? args[3] : Path.Combine(args[0], "runs.sqlite3");
var settings = new SimulationSettings { TrnexePath = args[1] };

using var daemon = new Daemon(databasePath, maxConcurrent: maxConcurrent);
foreach (string deck in decks)
{
    daemon.Add(deck, settings, label: Path.GetFileNameWithoutExtension(deck));
}

Console.WriteLine($"Running {decks.Length} decks, {maxConcurrent} at a time, in {daemon.DatabasePath} (session {daemon.SessionId})");

// Each finished run is reported once; a run is saved as finished only once.
int finished = 0;
while (finished < decks.Length)
{
    foreach (SimulationInfo run in daemon.Wait().Runs.Where(run => run.IsFinished))
    {
        finished++;
        string outcome = run.Succeeded ? "ok" : $"FAILED ({run.Status?.Status}) {run.Error}";
        Console.WriteLine($"[{finished}/{decks.Length}] {run.Label}: {outcome}");
    }
}

daemon.Shutdown();

// The database answers any later question; here, why each failed run failed.
IReadOnlyList<SimulationInfo> runs = daemon.Database.GetRuns(sessionId: daemon.SessionId, state: SimulationState.Finished);
SimulationInfo[] failed = runs.Where(run => !run.Succeeded).ToArray();
Console.WriteLine($"{runs.Count - failed.Length} succeeded, {failed.Length} failed");
foreach (SimulationInfo run in failed)
{
    foreach (LogEvent log in daemon.Database.GetLogs(run.RunId).Where(log => log.Severity == "Fatal"))
    {
        Console.WriteLine($"  {run.Label} at {log.Time} h: {log.Message}");
    }
}

return failed.Length == 0 ? 0 : 1;
