![TRNRun](https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.png)

Thin .NET client for running and monitoring
[TRNSYS](https://www.trnsys.com/) batch simulations. The package includes the
`trnrun.exe` runner and the
[`trnrund.exe`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund)
daemon. `TRNRunDaemon` has one async method per trnrund command and returns
simulations as typed `Simulation` records.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Run a batch](#run-a-batch)
- [`SimulationSettings`](#simulationsettings)
- [`TRNRunDaemon`](#trnrundaemon)
- [`Simulation`](#simulation)
- [Follow progress](#follow-progress)
- [Examples](#examples)

## Requirements

- Windows x64
- .NET 10
- TRNSYS 17 or 18
- Optional: [Type3830 Progress Tracker](https://github.com/NRCan/TRNRun/tree/main/components/type3830) for
  progress and stall monitoring

No NuGet dependencies; trim- and AOT-compatible.

## Installation

```powershell
dotnet add package TRNRun
```

## Quick start

```csharp
using TRNRun;

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 1);
long simId = await daemon.AddAsync(@"C:\path\to\deck.dck", new SimulationSettings { WatchTmp = true });
Simulation simulation = await daemon.WaitForFinishedAsync(simId);

if (simulation.Succeeded == true)
{
    Console.WriteLine($"Completed: {simulation.DeckFile}");
}
else
{
    Console.WriteLine($"Failed: {simulation.DeckFile}");
}
```

## Run a batch

```csharp
using TRNRun;

string[] decks = [.. Directory.EnumerateFiles(@"C:\path\to\decks", "*.dck").Order()];
var settings = new SimulationSettings { WatchTmp = true };

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 4);
var simIds = new List<long>();
foreach (string deck in decks)
{
    simIds.Add(await daemon.AddAsync(deck, settings));
}

Simulation[] simulations = await Task.WhenAll(simIds.Select(simId => daemon.WaitForFinishedAsync(simId)));
int succeeded = simulations.Count(sim => sim.Succeeded == true);
Console.WriteLine($"{succeeded} succeeded, {decks.Length - succeeded} failed");
```

## `SimulationSettings`

`SimulationSettings` defines how one deck is launched and monitored. Each
property that is set becomes one
[TRNRun Runner option](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#settings);
a property left at `null` keeps the runner's default, listed below. trnrund
checks the values when the simulation is added, so a bad value throws
`RequestException` from `AddAsync`.

Durations are `TimeSpan`s, passed as whole milliseconds rounded up. For the
timeouts, `Timeout.InfiniteTimeSpan` and `TimeSpan.Zero` both mean no limit.

It is an immutable record: derive variants with `with`:

```csharp
using TRNRun;

var settings = new SimulationSettings { WatchTmp = true, PollInterval = TimeSpan.FromMilliseconds(10) };
await daemon.AddAsync(deck, settings);                                                         // WatchTmp = true, PollInterval = 10 ms
await daemon.AddAsync(deck);                                                                   // every runner default
await daemon.AddAsync(deck, settings with { PollInterval = TimeSpan.FromMilliseconds(20) });   // WatchTmp = true, PollInterval = 20 ms
```

### Executable and window

- _`TrnexePath`_ (`string?`, default: `C:\TRNSYS18\Exe\TrnEXE64.exe`)

  Path to the `TrnEXE64.exe` or `TrnEXE.exe` executable. A relative path
  resolves from the current directory; a missing file throws
  `FileNotFoundException` from `AddAsync` before the simulation is queued.

- _`GuiVisibility`_ (`GuiVisibility?`, default: `Hidden`)

  Controls the TRNSYS simulation window:

  - `KeepOpen`: show the window and leave it open after the simulation.
  - `AutoClose`: show the window and close it after the simulation.
  - `Minimized`: minimize the window and leave it open afterward.
  - `MinimizedAuto`: minimize the window and close it afterward.
  - `Hidden`: hide the window and close it after the simulation.

### Launch detection

- _`WaitForGui`_ (`bool?`, default: `true`)

  Wait for a recognized TRNSYS simulation window as part of the launch-readiness checks.

- _`WaitForLst`_ (`bool?`, default: `true`)

  Wait for the component-order header in the deck's `.lst` file.

- _`WaitForTmp`_ (`bool?`, default: `false`)

  Wait for a Type3830 `.tmp` file. Do not enable this for a deck without
  Type3830, or launch detection will wait until its deadline.

- _`DetectTimeout`_ (`TimeSpan?`, default: 300 seconds)

  Maximum time to wait for launch readiness. Set to
  `Timeout.InfiniteTimeSpan` to wait indefinitely. The runner holds the launch
  mutex for the current Windows session until detection completes.

- _`ExtraDelay`_ (`TimeSpan?`, default: `TimeSpan.Zero`)

  Additional delay after all enabled readiness checks pass.

### Runtime monitoring

- _`PollInterval`_ (`TimeSpan?`, default: 100 milliseconds)

  Polling interval for the TRNSYS process and output files; at least 1
  millisecond.

- _`WatchLog`_ (`bool?`, default: `true`)

  Read the deck's `.log` file and report its entries as `Logs`.

- _`WatchTmp`_ (`bool?`, default: `false`)

  Read Type3830 `.tmp` updates and report the simulation period and progress.
  Required for progress-based `SimulationStatus.Cancelled` and
  `SimulationStatus.Stalled` outcomes. Without Type3830 in the deck, an early
  exit is reported as `Done`.

- _`WatchTimeout`_ (`TimeSpan?`, default: unlimited)

  Maximum runtime-monitoring duration.

- _`StallTimeout`_ (`TimeSpan?`, default: disabled)

  Maximum time without simulation-time progress. Requires `WatchTmp = true`
  and a valid Type3830 snapshot.

- _`KillOnTimeout`_ (`bool?`, default: `false`)

  Terminate the TRNSYS process when launch detection or runtime monitoring
  times out. If disabled, a detection timeout proceeds to runtime monitoring;
  after a runtime-monitoring timeout, the runner stops polling and waits for
  the process to exit.

- _`KillOnStall`_ (`bool?`, default: `false`)

  Terminate the TRNSYS process after detecting a stall. Without it, the runner
  waits for the process to exit.

### Output and cleanup

- _`CleanOnSuccess`_ (`bool?`, default: `false`)

  Delete `.tmp`, `.log`, `.lst`, and `.PTI` sidecar files after a successful
  run.

- _`Severity`_ (`LogSeverity?`, default: `Notice`)

  Minimum reported log severity: `Notice`, `Warning`, or `Fatal`.

- _`WriteEvents`_ (`bool?`, default: `false`)

  Mirror the runner events to a `.jsonl` file beside the deck, replacing any
  existing file when the run starts.

A configuration with every property set explicitly:

```csharp
using TRNRun;

var settings = new SimulationSettings
{
    TrnexePath = @"C:\TRNSYS18\Exe\TrnEXE64.exe",
    GuiVisibility = GuiVisibility.Hidden,
    WaitForGui = true,
    WaitForLst = true,
    WaitForTmp = true,
    DetectTimeout = TimeSpan.FromMinutes(5),
    ExtraDelay = TimeSpan.Zero,
    PollInterval = TimeSpan.FromMilliseconds(100),
    WatchLog = true,
    WatchTmp = true,
    WatchTimeout = TimeSpan.FromMinutes(5),
    StallTimeout = TimeSpan.FromMinutes(5),
    CleanOnSuccess = true,
    KillOnTimeout = true,
    KillOnStall = true,
    Severity = LogSeverity.Notice,
    WriteEvents = false,
};
```

## `TRNRunDaemon`

`TRNRunDaemon` owns one `trnrund.exe` and has one async method per
[trnrund command](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#request-protocol).
Nothing runs in the background: each `Simulation` it returns is a snapshot, so
ask again for the current one.

Requests are thread-safe: they take turns on the one pipe. A
`CancellationToken` only cancels the wait for an earlier request; a request
already sent runs to its reply, so the pipe never gets out of step. Disposing
waits for the request in progress, then closes trnrund's stdin, so it kills
every unfinished run and exits; waiting and later calls throw
`ObjectDisposedException`. Prefer `await using`: `Dispose` blocks while
trnrund exits.

### Parameters

`TRNRunDaemon.StartAsync` starts trnrund and returns once it answers:

- _`workers`_ (`int?`, default: logical processor count minus one)

  Maximum number of simulations running at once. Additional simulations wait
  in the queue.

- _`trnrundPath`_ (`string?`, default: bundled `trnrund.exe`)

  Path to the `trnrund.exe` executable.

- _`trnrunPath`_ (`string?`, default: bundled `trnrun.exe`)

  Path to the `trnrun.exe` executable.

- _`cancellationToken`_ (`CancellationToken`, default: none)

  Stops waiting for trnrund to answer; the half-started trnrund is then shut
  down.

The bundled executables are the ones the package copies to `native/` beside
your application. An explicitly configured daemon:

```csharp
using TRNRun;

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(
    workers: 4,
    trnrundPath: @"C:\path\to\trnrund.exe",
    trnrunPath: @"C:\path\to\trnrun.exe");
```

### Methods

Every method also takes an optional `CancellationToken`.

- _`AddAsync(string deckFile, SimulationSettings? settings = null, string? label = null) -> Task<long>`_

  Queue `deckFile` and return its `simId`. A relative path resolves from the
  current directory; `label` is free text stored with the simulation.

- _`GetSimulationAsync(long simId, bool withLogs = false) -> Task<Simulation>`_

  Return one simulation, without `Logs` unless `withLogs` is `true`.

- _`GetSimulationsAsync(SimulationState state, bool withLogs = false) -> Task<IReadOnlyList<Simulation>>`_

  Return every unreleased simulation in `state`, oldest first.

- _`WaitForFinishedAsync(long simId, TimeSpan? pollInterval = null) -> Task<Simulation>`_

  Poll one simulation, every half second by default, until it is `Finished`,
  and return it without `Logs`. Cancelling stops the wait, not the simulation.

- _`CancelAsync(long simId) -> Task`_

  Stop a queued or running simulation; one already finished is left unchanged.
  It then finishes with status `Cancelled`.

- _`ReleaseAsync(long simId) -> Task`_

  Forget a finished simulation and its logs.

- _`RequestAsync(JsonObject request) -> Task<JsonObject>`_

  Send any raw trnrund request and return its raw response.

- _`DisposeAsync() -> ValueTask`_, _`Dispose()`_

  Stop `trnrund.exe`, killing unfinished runs. If it does not exit within 10
  seconds, it is killed with its child processes.

`RequestException` is thrown when trnrund refuses a request, such as for a
missing deck, an unknown `simId`, or releasing an unfinished run, and
`DaemonExitedException`, with its exit code and stderr, when it no longer
answers. Both derive from `TRNRunException`, which is also thrown, wrapping the
parse error, when a reply breaks the protocol. Simulation outcomes do not
throw: inspect each simulation's `Succeeded`, `Status`, and `ExitCode` instead.

Example daemon workflow with every method:

```csharp
using System.Text.Json.Nodes;
using TRNRun;

var settings = new SimulationSettings { WatchTmp = true };
await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 2);

long first = await daemon.AddAsync(@"C:\path\to\first.dck", settings);
long second = await daemon.AddAsync(@"C:\path\to\second.dck", settings, label: "second");

Console.WriteLine(await daemon.GetSimulationAsync(first));
Console.WriteLine($"Running: {(await daemon.GetSimulationsAsync(SimulationState.Running)).Count}");

await daemon.CancelAsync(second);
await daemon.WaitForFinishedAsync(second);
Simulation cancelled = await daemon.GetSimulationAsync(second, withLogs: true);
Console.WriteLine($"Second status: {cancelled.Status}, {cancelled.Logs.Count} log entries");
await daemon.ReleaseAsync(second);

try
{
    await daemon.ReleaseAsync(first);
}
catch (RequestException error)
{
    Console.WriteLine($"First not finished: {error.Message}");
}

JsonObject raw = await daemon.RequestAsync(new JsonObject { ["cmd"] = "simulations", ["state"] = "RUNNING" });
Console.WriteLine($"Raw response: {raw}");
```

## `Simulation`

`Simulation` is an immutable snapshot of one run, holding trnrund's
[simulation fields](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#simulation-fields)
in PascalCase. A nullable property is `null` until the runner reports it.

### Properties

- _`SimId`_ (`long`)

  Identifier assigned by the daemon, never reused.

- _`DeckFile`_ (`string`)

  Absolute path to the submitted deck.

- _`Label`_ (`string?`)

  Label it was added with.

- _`TrnrunArgs`_ (`IReadOnlyList<string>`)

  Runner options it was added with, such as `--watchTmp:true`.

- _`State`_ (`SimulationState`)

  `Queued` while waiting for a worker, `Running` once the runner started, and
  `Finished` once it completed, failed, or was cancelled. Wait on `State`, not
  `Status`: `Status` can already be `Done` while `State` is `Running`.

- _`Status`_, _`StatusMessage`_ (`SimulationStatus?`, `string?`)

  Latest runner status and its detail; trnrund's `trnrunStatus` and
  `trnrunMessage`.

- _`Succeeded`_ (`bool?`)

  Set once finished. `true` only with status `Done`, exit code `0`, and no
  `Error`.

- _`ExitCode`_ (`int?`)

  Runner exit code; `null` if it was cancelled or never started.

- _`Error`_ (`string?`)

  Why the daemon failed or cancelled the run.

- _`SimTime`_, _`Percent`_ (`double?`), _`Elapsed`_, _`Eta`_ (`TimeSpan?`)

  Latest Type3830 progress. `SimTime` is in simulated hours and `Percent` is a
  fraction from `0` to `1`.

- _`StartTime`_, _`StopTime`_, _`TimeStep`_ (`double?`)

  Simulation period reported by Type3830, in simulated hours.

- _`Setting`_ (`JsonElement?`)

  Settings the runner applied, its defaults included, keyed by the runner's
  camelCase names.

- _`Notices`_, _`Warnings`_, _`Fatals`_ (`int`)

  Number of log entries so far, by severity, counted even when `Logs` is empty.

- _`Logs`_ (`IReadOnlyList<LogEvent>`)

  Log entries, oldest first; empty unless asked for with `withLogs`.

- _`SubmittedAt`_, _`StartedAt`_, _`FinishedAt`_ (`DateTimeOffset?`)

  UTC times; `StartedAt` stays `null` for a simulation that never started.

An example inspecting every property:

```csharp
using TRNRun;

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 1);
long simId = await daemon.AddAsync(@"C:\path\to\deck.dck", new SimulationSettings { WatchTmp = true });
await daemon.WaitForFinishedAsync(simId);
Simulation simulation = await daemon.GetSimulationAsync(simId, withLogs: true);

Console.WriteLine($"ID: {simulation.SimId}");
Console.WriteLine($"Deck: {simulation.DeckFile}");
Console.WriteLine($"Label: {simulation.Label}");
Console.WriteLine($"Runner options: {string.Join(" ", simulation.TrnrunArgs)}");
Console.WriteLine($"State: {simulation.State}");
Console.WriteLine($"Status: {simulation.Status} {simulation.StatusMessage}");
Console.WriteLine($"Succeeded: {simulation.Succeeded}");
Console.WriteLine($"Exit code: {simulation.ExitCode}");
Console.WriteLine($"Error: {simulation.Error}");
Console.WriteLine($"Progress: {simulation.Percent} at {simulation.SimTime} h");
Console.WriteLine($"Elapsed: {simulation.Elapsed}, ETA: {simulation.Eta}");
Console.WriteLine($"Period: {simulation.StartTime} to {simulation.StopTime} by {simulation.TimeStep} h");
Console.WriteLine($"Runner settings: {simulation.Setting}");
Console.WriteLine($"Notices: {simulation.Notices}");
Console.WriteLine($"Warnings: {simulation.Warnings}");
Console.WriteLine($"Fatals: {simulation.Fatals}");
Console.WriteLine($"Logs: {string.Join(Environment.NewLine, simulation.Logs)}");
Console.WriteLine($"Times: {simulation.SubmittedAt}, {simulation.StartedAt}, {simulation.FinishedAt}");
```

## Follow progress

To draw your own display, poll the running simulations and release each one
once finished:

```csharp
using TRNRun;

string[] decks = [@"C:\path\to\first.dck", @"C:\path\to\second.dck"];
var settings = new SimulationSettings { WatchTmp = true };

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 2);
foreach (string deck in decks)
{
    await daemon.AddAsync(deck, settings);
}

int remaining = decks.Length;
while (remaining > 0)
{
    foreach (Simulation sim in await daemon.GetSimulationsAsync(SimulationState.Running))
    {
        string progress = sim.Percent is { } percent ? $"{percent:P0}" : "no progress yet";
        Console.WriteLine($"[{sim.SimId}] {Path.GetFileName(sim.DeckFile)}: {progress} ({sim.Status})");
    }

    foreach (Simulation sim in await daemon.GetSimulationsAsync(SimulationState.Finished))
    {
        Console.WriteLine($"[{sim.SimId}] {Path.GetFileName(sim.DeckFile)}: {sim.Status}");
        await daemon.ReleaseAsync(sim.SimId);
        remaining--;
    }

    await Task.Delay(TimeSpan.FromSeconds(1));
}
```

## Examples

Runnable examples are in
[`examples`](https://github.com/NRCan/TRNRun/tree/main/libraries/dotnet/examples).

```powershell
# One simulation in the console.
dotnet run --project examples/TRNRun.Example

# 10 simulations, two at a time.
dotnet run --project examples/TRNRun.BatchExample -- 2

# A minimal GUI, and a fuller one.
dotnet run --project examples/TRNRun.SimpleGuiExample
dotnet run --project examples/TRNRun.GuiExample
```

The console examples take an optional TrnEXE path as their last argument
(default `C:\TRNSYS18\Exe\TrnEXE64.exe`).
