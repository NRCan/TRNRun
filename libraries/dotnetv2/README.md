# TRNRun for .NET

A thin wrapper for the Windows `trnrund` daemon: submit TRNSYS runs to it, and
follow them through the SQLite database it keeps up to date. Requires Windows
x64, .NET 10 (`net10.0-windows`), and the native `trnrund.exe` and
`trnrun.exe`, which the package bundles. Real simulations also require TRNSYS.
There are no NuGet runtime dependencies: the database is read through the
`winsqlite3.dll` built into Windows 10 and later, the same SQLite trnrund
writes it with.

```csharp
using TRNRun;

var settings = new SimulationSettings { WatchTmp = true };

using var daemon = new Daemon("runs.sqlite3", maxConcurrent: 2);
long runId = daemon.Add("model.dck", settings);

SimulationInfo? finished = null;
while (finished is null)
{
    Changes changes = daemon.Wait(); // Blocks until trnrund saves something; throws if it crashed.
    finished = changes.Runs.FirstOrDefault(run => run.RunId == runId && run.IsFinished);
}

Console.WriteLine($"{finished.Succeeded} {finished.Status}");
IReadOnlyList<LogEvent> logs = daemon.Database.GetLogs(runId);
```

## API

- `new Daemon(databasePath = null, maxConcurrent = null, trnrundPath = null,
  trnrunPath = null, requestTimeout = null)` starts the daemon, waits for its
  `ready` reply, and opens its database. Its change notifications are read
  from then on.
  - `databasePath: null` keeps the runs in a temporary database, deleted by
    `Dispose()`. A given path is created if missing; its directory must exist.
    An existing database keeps its runs and logs, and the daemon continues its
    run numbers in a new session. For an empty history, use a new file.
  - `maxConcurrent` limits simulations running at once; `null` means
    `max(CPUs - 1, 1)`.
  - `trnrundPath` and `trnrunPath` are the daemon and the TRNRun runner it
    launches; they default to `Daemon.DefaultTrnrundPath` and
    `Daemon.DefaultTrnrunPath`, the executables bundled in `native/` beside the
    application. Pass a path to use other builds.
  - A request that gets no reply within `requestTimeout` (default
    `Daemon.DefaultRequestTimeout`, 60 seconds) throws `TimeoutException`.

  Relative paths resolve from the current working directory. A missing
  trnrund throws `FileNotFoundException`; a daemon that fails to start throws
  `DaemonException` with its message, such as a database in use by another
  trnrund.
- `Add(deckFile, trnrunArgs = null, label = null) -> long` submits a run and
  returns the run ID the daemon assigned. Run IDs are never reused in a
  database. `trnrunArgs` is a `SimulationSettings` or raw CLI arguments;
  omitting it keeps the runner's defaults. `label` is an optional tag saved
  with the run. A relative `deckFile` resolves from the working directory at
  the time of the call. The call returns once the run is saved, not when it
  starts. A rejected run throws `ArgumentException` with trnrund's reason; a
  request to a daemon that has exited throws `DaemonException` with its exit
  code and stderr message, such as
  `trnrund exited with code 2: 'maxConcurrent' must be at least 1`.
- `Cancel(runId)` stops one run and returns once the daemon has recorded the
  request. A queued run is already `Finished` with status `Cancelled` on
  return. A running one has its TRNRun killed, along with TRNSYS, and becomes
  `Finished`/`Cancelled` shortly after. Its `Error` tells which:
  `Not started: cancelled by the client` or
  `Interrupted: cancelled by the client`. Cancelling a finished run changes
  nothing. An unknown `runId` throws `ArgumentException`.
- `Wait(timeout = null) -> Changes` blocks until the daemon announces newly
  saved changes, then returns them: `changes.Runs`, the latest
  `SimulationInfo` of each run that changed, and `changes.Logs`, the new
  `LogEvent`s. It returns at once if changes are already waiting, and empty
  `Changes` (`IsEmpty`) after `timeout`. It starts with what this daemon
  changes, not the database's earlier history.
- `Poll() -> Changes` returns the same without blocking, for timers such as a
  GUI's.
- Both throw `DaemonException` once the daemon has exited unexpectedly **and**
  every change it saved has been returned, so a loop over them never hangs on
  a crashed daemon and never misses its last saves. `GetExitError()` returns
  the same exception, or `null`, without reading anything.
- `Shutdown(cancelRunning = false, timeout = null)` cancels queued runs, waits
  for running ones, and waits for the daemon to exit. With
  `cancelRunning: true`, running runs are killed instead. If they still run
  after `timeout`, the daemon is told to stop at once, which saves them as
  interrupted. The database stays readable until `Dispose()`.
- `Dispose()` closes the database, then closes stdin and waits for the daemon
  to exit, **interrupting unfinished simulations**, and deletes a temporary
  database. A daemon that has not exited 10 seconds after stdin closes is
  killed, with its simulations, so `Dispose()` never hangs. It is safe to call
  more than once, including after the daemon crashed. Leaving a `using` block
  calls it; wait for your runs inside the block.
- `DatabasePath` is the path returned by the daemon, `SessionId` the session
  its runs are recorded in, and `Database` a [`Database`](#reading-the-database)
  that `Wait()` and `Poll()` read through.

Every member may be called from any thread. `Poll()` and `Wait()` hand out
each change once, so call them from one consumer; another reader opens its own
`Database` and calls `daemon.WaitForChange(database.Revision)` to block.

A run finishes when its `State` is `Finished`; check `Succeeded` to
distinguish success from failure. See the
[daemon documentation](../../components/trnrund/README.md) for the protocol,
the complete database schema, and CLI options.

Each `trnrund` started is placed in a process-wide, kill-on-close Windows Job
Object, so if the application is killed outright, the daemon and every TRNRun
and TRNSYS process under it are killed too, rather than holding a licence seat.

## Reading the database

`Database` reads a trnrund database, with or without a running daemon, and
without TRNSYS. It returns typed records.

```csharp
using TRNRun;

using var database = new Database("runs.sqlite3");
Console.WriteLine(string.Join(", ", database.CountRunsByState()));

foreach (SimulationInfo run in database.GetRuns(state: SimulationState.Finished))
{
    Console.WriteLine($"{run.RunId} {run.Label} {run.Succeeded} {run.Status}");
}

Changes changes = database.Poll(); // Everything so far; later polls return only what is new.
```

- `new Database(path, afterRevision = 0, afterLogId = 0)` opens an existing
  database read-only. It does not create or migrate one; the schema version
  must be `Database.SchemaVersion` (`3`), or it throws `InvalidDataException`
  after closing. SQLite failures, such as a missing file, throw
  `DatabaseException` with SQLite's message and `ResultCode`. A `using` block
  closes it; so does `Dispose()`.
- `Poll() -> Changes` returns the runs and logs saved since the previous
  poll, read from one consistent snapshot, and advances past them. The first
  poll starts after `afterRevision` and `afterLogId`; `SeekEnd()` skips
  everything saved so far. The positions are readable as `Revision` and
  `LogId`. Runs are latest snapshots, not an event history: intermediate
  states between polls can be skipped.
- `GetRun(runId)` returns a `SimulationInfo`, or `null` for an unknown ID.
- `GetLogs(runId)` returns its `LogEvent`s, oldest first.
- `GetRuns(sessionId = null, state = null)` returns the runs of one session,
  in one state, or both, in the order they last changed.
- `CountRunsByState(sessionId = null)` returns a dictionary such as
  `{Queued: 40, Running: 2, Finished: 103}`, with every state present.
- `Execute(sql, params parameters)` runs a custom query and returns its
  `DatabaseRow`s, read in full before it returns. Bind values with `?`
  parameters rather than formatting them into SQL; a `SimulationState` binds
  as its saved name, such as `FINISHED`.

A `Database` serializes calls from several threads; a `Daemon`'s is no
exception. Anything trnrund saved that this package cannot read, such as a
state from a newer trnrund, throws `InvalidDataException` rather than being
misreported.

### Records

- `SimulationInfo` is one run: `RunId`, `State` (`Queued`, `Running`,
  `Finished`), `SessionId`, `Label`, `Revision`, `DeckFile`, `TrnrunArgs`,
  TRNRun's latest `Status` (`StatusEvent`: `Status`, `Message`), `Progress`
  (`ProgressEvent`: `Percent` from 0 to 1, simulated `Time`, `ElapsedMs`,
  `EtaMs`), `Config` (`ConfigEvent`: simulated `Start`, `Stop`, `Step`),
  `Setting` (`SettingEvent`: the settings TRNRun applied, one property per
  `SimulationSettings` property), `Notices`/`Warnings`/`Fatals`, `Succeeded`,
  `ExitCode`, `Error`, the UTC `SubmittedAt`/`StartedAt`/`FinishedAt`, and
  `IsFinished`. Events TRNRun has not reported yet are `null`.
- `LogEvent` is one TRNSYS log entry: `LogId`, `RunId`, `Severity` (`Notice`,
  `Warning`, `Fatal`), simulated `Time`, and, when TRNSYS attaches them,
  `UnitId`, `TypeId`, `MessageCode`, `Message`, `Information`.
- `DatabaseRow` is one row of a custom query, readable by column name
  (case-insensitive) or position. Values are SQLite's: `long`, `double`,
  `string`, `byte[]`, or `null`. `GetInt64`, `GetDouble` and `GetString`
  return them typed.

All records are immutable.

### Common queries

The helpers cover the usual questions; for anything else, query the `runs`
and `logs` tables directly. The
[daemon documentation](../../components/trnrund/README.md#reading-the-database)
describes every column.

```csharp
// Failed runs and why. Only FINISHED runs have a succeeded value.
IReadOnlyList<DatabaseRow> failed = database.Execute(
    "SELECT run_id, label, trnrun_status, error, fatals FROM runs"
    + " WHERE state = 'FINISHED' AND NOT succeeded ORDER BY revision");

// Wall-clock duration in seconds of each run that started and finished.
IReadOnlyList<DatabaseRow> durations = database.Execute(
    "SELECT run_id, (julianday(finished_at) - julianday(started_at)) * 86400 AS seconds"
    + " FROM runs WHERE finished_at IS NOT NULL AND started_at IS NOT NULL");

// Fatal log entries of one run, with the TRNSYS unit and type that raised them.
IReadOnlyList<DatabaseRow> fatals = database.Execute(
    "SELECT sim_time, unit_id, type_id, message FROM logs"
    + " WHERE run_id = ? AND severity = 'Fatal' ORDER BY log_id",
    1);
double? seconds = durations[0].GetDouble("seconds");
```

## Simulation settings

`SimulationSettings` names and types every TRNRun option for IntelliSense.
Each property's documentation gives its units, CLI flag, and effects.

```csharp
var settings = new SimulationSettings
{
    TrnexePath = @"C:\TRNSYS18\Exe\TrnEXE64.exe",
    WatchTmp = true,
    WatchTimeoutMs = 3_600_000,
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
lists. `PollMs` controls the runner, not how often .NET reads results.

## Examples

Run from this directory, substituting real deck and TRNSYS paths:

```powershell
# One deck, following its progress; omit --progress if Type3830 is not in the deck.
dotnet run --project examples/TRNRun.Example -- "C:\decks\model.dck" "C:\TRNSYS18\Exe\TrnEXE64.exe" --progress

# Every .dck file in a directory, two at a time, kept in C:\decks\runs.sqlite3.
dotnet run --project examples/TRNRun.BatchExample -- "C:\decks" "C:\TRNSYS18\Exe\TrnEXE64.exe" 2
```

Both return `0` when every simulation succeeded, `1` when one failed, and `2`
for usage errors. Only run independent decks concurrently; the daemon does not
isolate shared TRNSYS output files.

`examples/TRNRun.GuiExample` is a WPF window that does the same interactively:

```powershell
# Optionally followed by decks or deck directories to add at once.
dotnet run --project examples/TRNRun.GuiExample -- "C:\decks"
```

Add decks with its buttons, on the command line, or by dropping files and
folders on it, then
follow each run's status, progress and logs as they arrive; select runs to see
only their logs, and double-click one to show its deck in Explorer. trnrund
starts with the first deck added, so the database and concurrency chosen then
apply until the window closes. It follows the daemon with `Poll()` on a UI
timer, and starts it, adds runs and cancels them on the thread pool.

## Database safety

The daemon never deletes runs or logs; a reused database keeps its history.
Keep the database on a local disk, with its `-wal` and `-shm` files beside it;
its parent directory must already exist. Only one daemon may own a database at
a time. A database written by an older trnrund (schema version 2) is refused;
start a new file.

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

Run SDK commands from this directory so `global.json` applies. The tests need
neither TRNSYS nor Python: they run the bundled trnrund with
`tests/TRNRun.FakeTrnrun`, which replays scripted decks in place of TRNRun, and
test the protocol layer against `tests/TRNRun.FakeTrnrund`.

Project-reference builds and NuGet consumers copy both executables to
`native/` beneath the application's build and publish directories; the
package's `buildTransitive/TRNRun.targets` keeps this layout for transitive
consumers. Keep `native/` when deploying, including with single-file publish.

Before packing, `packaging/Validate-NativeExecutables.ps1` checks that both
executables are win-x64 and that their `--version` equals the package
`Version` in `src/TRNRun/TRNRun.csproj`, currently `0.7.0`, following the
Python `hatch_build.py` convention. Keep it aligned with both `.nimble`
versions.
