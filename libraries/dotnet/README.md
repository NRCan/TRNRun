# TRNRun for .NET

A thin wrapper for the Windows `trnrund` daemon: submit TRNSYS runs to it, and
follow them through the SQLite database it keeps up to date. Requires Windows
x64, .NET 10 (`net10.0-windows`), and the native `trnrund.exe` and
`trnrun.exe`, which the package bundles. Real simulations also require TRNSYS.
The database is read with
[Microsoft.Data.Sqlite](https://learn.microsoft.com/dotnet/standard/data/sqlite/),
the package's only NuGet dependency.

This is the .NET port of the Python package's `trnrun.core`: `Daemon` starts
trnrund and submits runs, and you read the database with plain SQL, optionally
through the typed extension methods in `TrnrunDatabase`. Every call that waits
for trnrund has an asynchronous version taking a `CancellationToken`.

```csharp
using TRNRun;

await using Daemon daemon = await Daemon.StartAsync(new DaemonOptions { DatabasePath = "runs.sqlite3", MaxConcurrent = 4 });
long runId = await daemon.AddAsync("model.dck", new SimulationSettings { WatchTmp = true }, label: "case A");

// Only this daemon's changes. Throws DaemonExitedException if trnrund crashes.
await foreach (Changes changes in daemon.FollowAsync())
{
    if (changes.Runs.FirstOrDefault(run => run.RunId == runId && run.IsFinished) is { } finished)
    {
        Console.WriteLine($"{finished.Status} {finished.Succeeded} {finished.Error}");
        break;
    }
}
```

The blocking members work the same way: `Daemon.Start`, `Add`, and
`Follow` with `foreach`, with `using` instead of `await using`.

## Daemon

`Daemon.Start(options = null)` and `Daemon.StartAsync(options = null,
cancellationToken)` start trnrund and wait until it is ready. `DaemonOptions`
holds:

- `DatabasePath`: `null`, the default, keeps the runs in a temporary database,
  deleted when the daemon is disposed. A given path is created if missing; its
  directory must exist. An existing database keeps its runs and logs, and new
  runs continue their numbering in a new session.
- `MaxConcurrent` limits simulations running at once; `null` means
  `max(CPUs - 1, 1)`.
- `TrnrundPath` and `TrnrunPath` default to the executables bundled in
  `native/` beside the application.
- `RequestTimeout`: a request unanswered within it, 60 seconds by default,
  throws `TimeoutException`.

Relative paths resolve from the current working directory. Each member below
that waits for trnrund also has an `Async` version, such as `AddAsync`, whose
`CancellationToken` stops the wait:

- `Add(deckFile, trnrunArgs = null, label = null) -> long` submits a deck and
  returns its run ID once saved, not finished. `trnrunArgs` is a
  `SimulationSettings` or raw TRNRun options. Run IDs are never reused in a
  database. A cancelled `AddAsync` stops waiting for the reply, but trnrund may
  still add the run.
- `Cancel(runId)` stops a queued or running run, and leaves a finished one
  unchanged. A queued run is already `Finished` and `Cancelled` on return; a
  running one has its TRNRun killed and becomes so shortly after. Its `Error`
  tells which: `Not started: cancelled by the client` or
  `Interrupted: cancelled by the client`.
- `Shutdown(cancelRunning = false)` cancels queued runs, waits for running
  ones, and waits for trnrund to exit; with `cancelRunning: true`, running runs
  are cancelled too. `Shutdown(timeout, cancelRunning)` interrupts the runs
  still running after `timeout`, as disposing does, and so does cancelling
  `ShutdownAsync`, which then throws `OperationCanceledException`.
- `Dispose()` and `DisposeAsync()`, called when leaving a `using` or
  `await using` block, close trnrund's stdin, **interrupting unfinished runs**,
  wait for it to exit, and delete a temporary database. A trnrund that has not
  exited 10 seconds later is killed, so disposing never hangs. It is safe to do
  again, also after a crash. Afterwards, members throw
  `ObjectDisposedException`.
- `OpenDatabase()` opens the database read-only; see
  [`TrnrunDatabase.Open`](#database).
- `Follow(connection, after) -> IEnumerable<Changes>` and
  `FollowAsync(connection, after, cancellationToken) -> IAsyncEnumerable<Changes>`
  yield what trnrund saves after the `ChangePosition` `after`, such as
  `StartPosition`, as it saves it: each item is a `ReadChanges` that starts
  where the previous one stopped. The sequence ends once trnrund has closed and
  everything it saved was yielded, and throws `DaemonExitedException` after a
  crash. Leave the loop to stop following.
- `Follow()` and `FollowAsync(cancellationToken)` do the same from
  `StartPosition`, through a connection of their own that closes when the loop
  ends. Use them when you only follow; leave the loop before disposing the
  daemon, so a temporary database can be deleted.
- `WaitForChanges(afterRevision)`, which `Follow` is built on, blocks until
  trnrund saves a revision after `afterRevision`;
  `WaitForChanges(afterRevision, timeout) -> bool` returns `false` if
  `timeout` passes first, and `TimeSpan.Zero` never blocks. It returns at once
  if a newer revision was already announced, so a change saved while you were
  reading is never missed. Once trnrund has exited and nothing newer was saved,
  it throws `DaemonClosedException` after a shutdown and
  `DaemonExitedException` after a crash, so following never hangs and never
  misses trnrund's last saves. A waiter blocked when the daemon is disposed
  wakes with `DaemonClosedException`.
- `DatabasePath`, `SessionId`, and `StartPosition` come from trnrund's `ready`
  reply.

Every `Daemon` member is safe from any thread, and the asynchronous ones never
need the caller's synchronization context, so a GUI can await them on its UI
thread. A `SqliteConnection` is not thread-safe: give each thread its own. Open
it while the daemon runs and keep it: right after a crash, a new connection can
fail to open.

If the application is killed outright, trnrund sees its stdin close and
interrupts its runs as disposing does; trnrund's own kill-on-close Job Object
then stops every TRNRun and TRNSYS process under it.

## Errors

Every exception TRNRun throws itself is a `TrnrunException`:

| Exception | Thrown when |
| --------- | ----------- |
| `DaemonExitedException` | trnrund crashed or failed to start, such as on a database in use by another trnrund; has `ExitCode` and `Diagnostics` |
| `RequestRejectedException` | trnrund refused a request, such as a missing deck, a bad option, or an unknown run ID |
| `DaemonClosedException` | trnrund has ended normally, after a shutdown or a clean exit, so it no longer answers |
| `SchemaVersionException` | A database from another trnrund version |

Calling a member after disposal throws `ObjectDisposedException`, and a
cancelled call throws `OperationCanceledException`. A missing executable or
`TrnexePath` throws `FileNotFoundException`, and an unanswered request throws
`TimeoutException`. SQLite failures, such as opening a missing database, throw
Microsoft.Data.Sqlite's `SqliteException`. A row this package cannot read, such
as a state from a newer trnrund, throws `InvalidDataException` rather than
being misreported.

## Database

trnrund saves every run, its progress, and its TRNSYS logs to SQLite. The
[daemon documentation](../../components/trnrund/README.md#reading-the-database)
describes every column of the `runs` and `logs` tables. `TrnrunDatabase` opens
it and turns its rows into typed records, if you want them:

- `TrnrunDatabase.Open(path) -> SqliteConnection` opens an existing trnrund
  database read-only, with or without a daemon, and checks that its schema
  version is `TrnrunDatabase.SchemaVersion` (`3`). It never creates one.
  Pooling is off, so disposing the connection releases the file.
- `connection.ReadChanges(after = default) -> Changes` reads the runs and logs
  saved after the `ChangePosition` `after`, a run revision and a log ID, from
  one snapshot. The default reads the whole history. `changes.Runs` are the
  latest `SimulationInfo` of each changed run, in the order they last changed;
  `changes.Logs` are the new `LogEvent`s, oldest first; and `changes.Next` is
  where to read next. Call it outside any transaction of your own.
- `reader.GetSimulationInfo()` and `reader.GetLogEvent()` read the current row
  of a `SELECT *` on `runs` or `logs`, such as from a `SqliteDataReader`, as a
  `SimulationInfo` or `LogEvent`.
- `ToDatabaseName()` is the name saved for a `SimulationState`, such as
  `FINISHED`, a `SimulationStatus`, such as `DONE`, or a `LogSeverity`, such as
  `Fatal`, to compare with the `state`, `trnrun_status` or `severity` column.

### Records

- `SimulationInfo` is one run: `RunId`, `State` (`Queued`, `Running`,
  `Finished`), `DeckFile`, `SessionId`, `Label`, `Revision`, `TrnrunArgs`,
  TRNRun's latest `Status` (`SimulationStatus`) and `StatusMessage`, `Progress`
  (`ProgressEvent`: `Percent` from 0 to 1, simulated `Time`, and the
  wall-clock `Elapsed` and `Eta` as `TimeSpan`s), `Config` (`ConfigEvent`:
  simulated `Start`, `Stop`, `Step`), `Setting` (the settings TRNRun applied,
  keyed by camelCase flag name, as `JsonElement`s),
  `Notices`/`Warnings`/`Fatals`, `Succeeded`, `ExitCode`, `Error`, the UTC
  `SubmittedAt`/`StartedAt`/`FinishedAt`, and `IsFinished`. Properties are
  named after their columns and are `null` where the column is NULL; the
  members trnrund never leaves NULL are `required`. `Succeeded` stays `null`
  until the run finishes.
- `LogEvent` is one TRNSYS log entry: `LogId`, `RunId`, `Severity`
  (`LogSeverity`: `Notice`, `Warning`, `Fatal`), simulated `Time`, and, when
  TRNSYS attaches them, `UnitId`, `TypeId`, `MessageCode`, `Message`,
  `Information`.

All records are immutable.

### Common queries

For anything else, query the tables directly:

```csharp
using SqliteConnection connection = TrnrunDatabase.Open("runs.sqlite3");

// Fatal log entries of one run, as typed records.
using SqliteCommand fatals = connection.CreateCommand();
fatals.CommandText = "SELECT * FROM logs WHERE run_id = $run AND severity = $severity ORDER BY log_id";
fatals.Parameters.AddWithValue("$run", 1);
fatals.Parameters.AddWithValue("$severity", LogSeverity.Fatal.ToDatabaseName());
using (SqliteDataReader reader = fatals.ExecuteReader())
{
    while (reader.Read())
    {
        LogEvent log = reader.GetLogEvent();
        Console.WriteLine($"{log.Time} h, unit {log.UnitId}: {log.Message}");
    }
}

// Wall-clock duration in seconds of each run that started and finished.
using SqliteCommand durations = connection.CreateCommand();
durations.CommandText = "SELECT run_id, ROUND((julianday(finished_at) - julianday(started_at)) * 86400, 3)"
    + " FROM runs WHERE finished_at IS NOT NULL AND started_at IS NOT NULL";
using (SqliteDataReader reader = durations.ExecuteReader())
{
    while (reader.Read())
    {
        Console.WriteLine($"Run {reader.GetInt64(0)}: {reader.GetDouble(1):0.0} s");
    }
}
```

## Simulation settings

`SimulationSettings` names and types every TRNRun option for IntelliSense.
Each property's documentation names its CLI flag; `trnrun.exe --help` gives
the full effects.

```csharp
var settings = new SimulationSettings
{
    TrnexePath = @"C:\TRNSYS18\Exe\TrnEXE64.exe",
    WatchTmp = true,
    WatchTimeout = TimeSpan.FromHours(1),
    KillOnTimeout = true,
};
// Reuse settings directly with daemon.Add("model.dck", settings),
// or derive others with: settings with { GuiVisibility = GuiVisibility.Minimized }
```

Every property defaults to `null`, which passes nothing, so TRNRun's own
default applies; run `trnrun.exe --help` for those defaults.
`new SimulationSettings()` therefore passes no options at all. Only TRNRun
defines the defaults, so they cannot drift between TRNRun and this package.

`Daemon.Add()` calls `ToCliArgs()`, which returns unquoted arguments for the
properties that are set, checks that a set `TrnexePath` exists, and resolves it
from the working directory. The daemon checks the other values with TRNRun's
own parser when the run is added. `Daemon.Add()` also accepts raw CLI argument
lists. Durations are `TimeSpan`s, passed in whole milliseconds rounded up; a
timeout of `Timeout.InfiniteTimeSpan` or `TimeSpan.Zero` is unlimited.
`PollInterval` controls the runner, not how often .NET reads results.

## Examples

Run from this directory, substituting real deck and TRNSYS paths:

`TRNRun.Example` uses the asynchronous members, and `TRNRun.BatchExample` the
blocking ones:

```powershell
# One deck, following its progress; omit --progress if Type3830 is not in the deck. Ctrl+C interrupts it.
dotnet run --project examples/TRNRun.Example -- "C:\decks\model.dck" "C:\TRNSYS18\Exe\TrnEXE64.exe" --progress

# Every .dck file in a directory, two at a time, kept in C:\decks\runs.sqlite3.
dotnet run --project examples/TRNRun.BatchExample -- "C:\decks" "C:\TRNSYS18\Exe\TrnEXE64.exe" 2
```

Both return `0` when every simulation succeeded, `1` when one failed, and `2`
for usage errors. Only run independent decks concurrently; the daemon does not
isolate shared TRNSYS output files.

`examples/TRNRun.SimpleGuiExample` is the least a WPF window needs: it starts
trnrund when it opens, keeping `runs.sqlite3` in the working directory, adds decks picked in a file dialog, copies each
`SimulationInfo` and `LogEvent` from `FollowAsync` into two tables on the UI
thread, cancels a run per row, and stops trnrund when it closes. Start from it
when building your own GUI:

```powershell
dotnet run --project examples/TRNRun.SimpleGuiExample
```

`examples/TRNRun.GuiExample` is a fuller WPF window:

```powershell
# Optionally followed by decks or deck directories to add at once.
dotnet run --project examples/TRNRun.GuiExample -- "C:\decks"
```

Add decks with its buttons, on the command line, or by dropping files and
folders on it, then
follow each run's status, progress and logs as they arrive; select runs to see
only their logs, and double-click one to show its deck in Explorer. trnrund
starts with the first deck added, so the database and concurrency chosen then
apply until the window closes. An `await foreach` on the UI thread follows
`FollowAsync`, and every other call to the daemon is awaited too, so none blocks
the window.

## Database safety

The daemon never deletes runs or logs; a reused database keeps its history.
Keep the database on a local disk, with its `-wal` and `-shm` files beside it;
its parent directory must already exist. Only one daemon may own a database at
a time. A database from another schema version is refused; start a new file.

## Build, test and package

On Windows, install the .NET 10 SDK, then build both native executables from
the repository root with `just trnrun-bin` and `just trnrund-bin`. The library
links them directly from `components/trnrun/build/trnrun.exe` and
`components/trnrund/build/trnrund.exe`; a build fails with these instructions
if either is missing. Then, from this directory:

```powershell
dotnet build TRNRun.slnx --configuration Release
dotnet test TRNRun.slnx
dotnet pack src/TRNRun/TRNRun.csproj --configuration Release --no-build --output ../../dist
```

From the repository root, `just dotnet-test` builds both executables and runs
the tests, and `just dotnet-dist`, also run by `just deploy`, packs the
`.nupkg` and `.snupkg` into `dist/`.

Run SDK commands from this directory so `global.json` applies. The tests need
neither TRNSYS nor Python: they run the bundled trnrund with
`tests/TRNRun.FakeTrnrun`, which replays scripted decks in place of TRNRun, and
test the protocol layer against `tests/TRNRun.FakeTrnrund`.

Project-reference builds and NuGet consumers copy both executables to
`native/` beneath the application's build and publish directories; the
package's `buildTransitive/TRNRun.targets` keeps this layout for transitive
consumers. Keep `native/` when deploying, including with single-file publish.
Microsoft.Data.Sqlite brings its own native SQLite, `e_sqlite3.dll`, which
.NET deploys beside the application.

Before packing, `packaging/Validate-NativeExecutables.ps1` checks that both
executables are win-x64 and that their `--version` equals the package
`Version` in `src/TRNRun/TRNRun.csproj`, currently `0.8.0`, following the
Python `hatch_build.py` convention. Keep it aligned with both `.nimble`
versions.
