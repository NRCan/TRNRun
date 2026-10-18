// Example: running every deck in a directory and keeping the results in a database.
//
// Usage: TRNRun.BatchExample <deck-directory> <TrnEXE64.exe> [maxConcurrent] [database.sqlite3]
// maxConcurrent defaults to 4; the database defaults to runs.sqlite3 in the deck directory.
// A reused database keeps its earlier runs; this batch is its own session.

using Microsoft.Data.Sqlite;
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

// The blocking members suit a console batch; see TRNRun.Example for the asynchronous ones.
using Daemon daemon = Daemon.Start(new DaemonOptions { DatabasePath = databasePath, MaxConcurrent = maxConcurrent });
using SqliteConnection connection = daemon.OpenDatabase();
foreach (string deck in decks)
{
    daemon.Add(deck, settings, label: Path.GetFileNameWithoutExtension(deck));
}

Console.WriteLine($"Running {decks.Length} decks, {maxConcurrent} at a time, in {daemon.DatabasePath} (session {daemon.SessionId})");

// A finished run never changes again, so each one is read as finished once.
ChangePosition position = daemon.StartPosition;
var failed = new List<SimulationInfo>();
int finished = 0;
while (finished < decks.Length)
{
    daemon.WaitForChanges(position.Revision);
    Changes changes = connection.ReadChanges(position);
    position = changes.Next;
    foreach (SimulationInfo run in changes.Runs.Where(run => run.IsFinished))
    {
        finished++;
        if (run.Succeeded != true)
        {
            failed.Add(run);
        }

        string outcome = run.Succeeded == true ? "ok" : $"FAILED ({run.Status}) {run.Error}";
        Console.WriteLine($"[{finished}/{decks.Length}] {run.Label}: {outcome}");
    }
}

daemon.Shutdown();
Console.WriteLine($"{decks.Length - failed.Count} succeeded, {failed.Count} failed");

// The database answers any later question in plain SQL; here, why each failed run failed.
using SqliteCommand command = connection.CreateCommand();
command.CommandText = "SELECT * FROM logs WHERE run_id = $run AND severity = 'Fatal' ORDER BY log_id";
SqliteParameter runParameter = command.Parameters.Add("$run", SqliteType.Integer);
foreach (SimulationInfo run in failed)
{
    runParameter.Value = run.RunId;
    using SqliteDataReader reader = command.ExecuteReader();
    while (reader.Read())
    {
        LogEvent log = reader.GetLogEvent();
        Console.WriteLine($"  {run.Label} at {log.Time} h: {log.Message}");
    }
}

return failed.Count == 0 ? 0 : 1;
