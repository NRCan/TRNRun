# TRNRun for .NET

Run and monitor TRNSYS simulations from C# using the existing native
`trnrun.exe` runner and `trnrunq.exe` queue. The queue owns scheduling and
concurrency; the .NET library is a synchronous, single-threaded client with no
third-party runtime package dependencies.

## Requirements

- Windows x64 and .NET 10; target `net10.0-windows` in the consuming application.
- An installed, licensed TRNSYS 17 or 18. TRNSYS itself is not bundled.
- Optional [Type3830](https://github.com/NRCan/TRNRun/tree/main/components/type3830)
  in each deck for simulation progress and stall detection. Enable `WatchTmp`
  when using it; neither Type3830 nor TRNSYS is installed by this package.

NuGet packages include both native executables under
`runtimes/win-x64/native/`. No separate native download, Python installation, or
Nim installation is needed by package consumers. Framework-dependent
applications still require the .NET 10 runtime.

## Build and package from source

On Windows, install the .NET 10 SDK, Nim 2.2.10 or newer, Zig, and just. CI uses
Nim 2.2.10 and Zig 0.16.0, matching the existing native build toolchain. Run these
recipes from the repository root:

```powershell
just dotnet-build
just dotnet-pack
```

`dotnet-build` first invokes the existing `trnrun-bin` and `trnrunq-bin`
recipes, then builds `TRNRun.DotNet.sln` in Release, including both console
examples. `dotnet-pack` depends on that build and writes
`dist/TRNRun.0.6.1.nupkg`. Running only `just dotnet-pack` is sufficient to build
and package everything needed by the .NET client. No .NET tests or simulations
are run by these recipes.

For subsequent managed-only builds, after `just dotnet-native` has built both
native runners, run from `libraries/dotnet/`:

```powershell
dotnet build TRNRun.DotNet.sln --configuration Release
dotnet pack src/TRNRun/TRNRun.csproj --configuration Release --no-build --output ../../dist
```

Run SDK commands from this directory so `global.json` applies: it requires a
stable .NET 10 SDK starting at 10.0.100 and permits newer 10.0 feature bands.
Nullable references, implicit usings, XML API documentation, and warnings as
errors are enabled for the solution. The library enables unsafe blocks for
source-generated `LibraryImport` Windows interop.

### Native assets and version checks

The library project links the real build outputs directly:

| Source file, relative to repository root | NuGet asset |
| --- | --- |
| `components/trnrun/build/trnrun.exe` | `runtimes/win-x64/native/trnrun.exe` |
| `components/trnrunq/build/trnrunq.exe` | `runtimes/win-x64/native/trnrunq.exe` |

There is no checked-in binary, placeholder, staged duplicate, or automatic
executable download. A managed build fails with instructions to run
`just dotnet-native` if either output is missing. Source/project-reference
builds copy the linked files to `runtimes/win-x64/native/` beneath the application
output and publish directories. NuGet consumers use the SDK's native runtime
asset handling; a `win-x64` build/publish can place the executables beside the
application. The client must resolve both layouts relative to the application
base directory, not the current working directory. Keep both executables when
deploying; the package does not embed them in the managed assembly.

Before NuGet's `GenerateNuspec` target, including with `--no-build`,
`packaging/Validate-NativeRunners.ps1` checks **both** actual source executables:

1. Each file exists and has a Windows AMD64 PE header.
2. Each `--version` invocation exits successfully within ten seconds.
3. Each trimmed version string equals the evaluated NuGet `PackageVersion`
   exactly, following the Python `hatch_build.py` convention.

A missing file, wrong architecture, failed command, timeout, or version mismatch
fails packaging. Packing must run on Windows. Changing only `PackageVersion`
(or using a prerelease suffix) does not bypass the native version checks. Keep
`Version` in `src/TRNRun/TRNRun.csproj` aligned with both native `.nimble` package
versions and rebuild the runners when changing versions. The current shared
version is `0.6.1`.

The package also includes XML API documentation, this README, the repository
license, and third-party notices. The existing Windows distribution workflow
sets up .NET 10, builds both native components before the managed projects,
packs without rebuilding the managed code, and uploads `dist/*.nupkg` alongside
the other client distributions. It does not publish to a NuGet feed or add a
.NET test job.

### Install a locally built package

No public NuGet publication is assumed. From a consuming application's project
directory, add the locally built package, using the actual path to this checkout:

```powershell
dotnet add package TRNRun --version 0.6.1 --source C:\path\to\TRNRun\dist
```

Set the consuming project's `TargetFramework` to `net10.0-windows`. For an
explicitly x64 framework-dependent executable, also set `RuntimeIdentifier` to
`win-x64` and `SelfContained` to `false`, as the included examples do.

## Single simulation

```csharp
using TRNRun;

var config = new SimulationConfig
{
    TrnExePath = @"C:\TRNSYS18\Exe\TrnEXE64.exe",
    WatchTmp = true // Requires Type3830 in this deck.
};
var manager = new SimulationManager(
    maxConcurrent: 1,
    refreshInterval: TimeSpan.FromSeconds(1))
{
    ShowProgress = true
};

try
{
    Simulation simulation = manager.Add(@"C:\decks\example.dck", config);
    manager.Wait(simulation);
    Console.WriteLine($"{simulation.DeckPath}: {simulation.Status?.Status ?? "unknown"}");
    Console.WriteLine($"Succeeded: {simulation.Succeeded}");
    foreach (var log in simulation.Logs)
    {
        Console.WriteLine(log);
    }
}
finally
{
    manager.Shutdown();
}
```

Without Type3830, leave `WatchTmp` at its default `false`. `ShowProgress` controls
console rendering independently; it does not enable native progress monitoring.

## Executable examples

Build the native runners first using `just dotnet-native` from the repository
root, or use `just dotnet-build`. Then run from `libraries/dotnet/`, substituting
real deck and TRNSYS paths:

```powershell
# One deck; omit --progress if Type3830 is not in the deck.
dotnet run --project examples/TRNRun.Example --configuration Release -- "C:\decks\example.dck" "C:\TRNSYS18\Exe\TrnEXE64.exe" --progress

# All .dck files directly in this directory, with at most four concurrent runs.
dotnet run --project examples/TRNRun.BatchExample --configuration Release -- "C:\decks" "C:\TRNSYS18\Exe\TrnEXE64.exe" 4
```

- `examples/TRNRun.Example/Program.cs` uses `Add()` and `Wait(simulation)`, prints
  the final status, progress, and logs, and optionally enables the console display.
- `examples/TRNRun.BatchExample/Program.cs` submits a batch, consumes `Follow()`,
  and prints the success/failure totals and failed-run logs. Concurrency defaults
  to four when the last argument is omitted. It does not require Type3830 or
  enable `WatchTmp` by default.
- Both call `Shutdown()` in `finally`, return `0` for successful simulations,
  `1` for completed simulation failures, and `2` for usage errors. Unexpected
  exceptions propagate with a nonzero process exit code.

Only use independent decks/output files concurrently; the queue does not
isolate shared TRNSYS output files for you.

## Manager API and lifecycle

```csharp
public SimulationManager(
    int? maxConcurrent = null,
    TimeSpan? refreshInterval = null,
    string? trnRunQueuePath = null);

public bool ShowProgress { get; set; } // Default: false.
public Simulation Add(string deckPath, SimulationConfig config);
public void Wait(Simulation? simulation = null);
public IEnumerable<Simulation> Follow(Simulation? simulation = null);
public void Shutdown();
```

- Default concurrency is `Math.Max(Environment.ProcessorCount - 1, 1)`.
- `Add()` returns after native `QUEUE/ACCEPTED`: a worker has picked up the
  request. It can block while workers are occupied, and processes other runs'
  events while waiting. Acceptance does not imply simulation success.
- `Wait(simulation)` waits for one run; `Wait()` waits for all accepted runs.
  Neither shuts down the queue, so further submissions are possible afterward.
- `Follow(simulation)` or `Follow()` processes events while enumerated and yields
  the existing, live `Simulation` objects. It does not produce immutable
  snapshots or replay events consumed by earlier calls (including `Add()`).
- Reading for a selected run still updates all other runs. The selected object
  must belong to the manager. Already completed runs return immediately.
- `Simulations`, `Succeeded`, `Failed`, and each simulation's `Logs` return
  collection copies, not their backing collections. The simulations inside
  those collections remain live objects.
- `Shutdown()` closes queue stdin, drains stdout to EOF, waits for the queue to
  exit, and releases owned resources. It **drains accepted work, not cancels it**,
  and can block indefinitely, particularly if timeout/stall killing is disabled.
  Unexpected EOF with outstanding runs and queue exit failures are errors; the
  client does not invent completion events or retry submissions. If a transport
  failure makes draining impossible, emergency cleanup attempts to terminate and
  reap the process tree before reporting the error. This is not cancellation of
  normally draining work. After shutdown, repeated `Shutdown()` calls are harmless;
  new submissions and waits are rejected.
- Use `try`/`finally` for explicit cleanup. `SimulationManager` does **not**
  implement `IDisposable` or `IAsyncDisposable`, expose `Dispose()`, or support
  manager `using` statements. Do not rely on garbage collection for shutdown.
  A Windows Job Object is best-effort protection against orphaned native child
  processes if the host exits unexpectedly, not a substitute for `Shutdown()`.

### Following updates yourself

For a manager and simulation already created inside the `try` block above,
replace `Wait(simulation)` with:

```csharp
manager.ShowProgress = false;
foreach (Simulation updated in manager.Follow(simulation))
{
    Console.WriteLine($"{updated.Id}: {updated.Status}; progress: {updated.Progress}");
}
```

Enumerate promptly. Breaking out early stops pumping events, not the simulation;
resume with `Wait()`, another `Follow()` enumeration, or `Shutdown()`.

### Single-threaded limitation and console output

Use the thread that created the manager and only one active manager operation
at a time. Concurrent calls, interleaved `Follow()` enumerations, and reentrant
manager calls while following are rejected. Dispose a manually obtained Follow
enumerator before calling another operation; `foreach` does this automatically. There are no background readers, tasks, subscriptions,
or asynchronous methods. State advances only while `Add()`, `Wait()`, `Follow()`
enumeration, or `Shutdown()` reads queue output. Long pauses between calls or
inside a `Follow()` loop can fill stdout and stall the queue and its children.

`ShowProgress` is a public read/write property, defaulting to `false`. Set it to
`true` to opt into a basic `System.Console` display of deck, status, log counts,
elapsed time, ETA, and available simulation progress. The constructor's
`refreshInterval` throttles **rendering only**. It is not a polling interval,
background timer, or state-update frequency, and there is no separate display
refresh property. Native polling is configured by `SimulationConfig.PollInterval`.

## Simulation state

| Property | Meaning |
| --- | --- |
| `Id` | Run identifier used to route native events. |
| `DeckPath` | Submitted deck path. |
| `Config` | Immutable configuration submitted for this run. |
| `IsAccepted` | The queue has reported `QUEUE/ACCEPTED`. |
| `IsFinished` | The queue has reported `QUEUE/COMPLETED`, not just a terminal status or 100% progress. |
| `Succeeded` | Finished, with the latest native runner status exactly `DONE`. |
| `Status` | Latest `StatusEvent`; its `Status` string preserves unknown native statuses. |
| `Progress` | Latest progress event, if available; not a completion signal. |
| `ConfigEvent`, `SettingEvent` | Latest native simulation bounds and effective runner settings. |
| `CompletionEvent` | Native queue completion metadata, including its nullable `ExitCode`. |
| `Logs` | Copy of the latest 5,000 native log entries, oldest first. |
| `LogCount`, `Notices`, `Warnings`, `Fatals` | Cumulative received counts, including entries evicted from history. |

A finished simulation that did not succeed appears in `manager.Failed`.
Missing native status/progress/exit-code information is not synthesized.

## Configuration

`SimulationConfig` is an immutable record with init-only properties. Create a
new record (or use `with`) to change settings for future submissions; do not
mutate an accepted run's configuration. Durations use `TimeSpan`, and nullable
timeouts use `null` (or zero) for unlimited/disabled behavior. Durations must
be whole milliseconds from zero through 2,147,483,647 (about 24.8 days), with
`PollInterval` at least one millisecond. Invalid enum values, unsupported deck
extensions, and missing deck/executable files are rejected before submission.

Call `config.Validate()` to check settings and runner/TRNSYS executable paths
without creating a manager or launching a process. It throws on invalid input
and does not modify the record. Submission validates automatically through
`SimulationConfig.ToCliArgs()`, an internal method that produces unquoted native
arguments. The manager validates the deck separately; the queue supplies its
path and run ID. Executable discovery is shared through `ExecutableResolver`.

| Property | Default | Purpose |
| --- | --- | --- |
| `TrnRunPath` | `null` | Use the bundled runner; set an explicit executable path to override it. |
| `TrnExePath` | `C:\TRNSYS18\Exe\TrnEXE64.exe` | Installed TRNSYS executable. |
| `GuiVisibility` | `GuiVisibility.Hidden` | Native TRNSYS window visibility policy. |
| `WaitForGui` | `true` | Wait for GUI detection. |
| `WaitForLst` | `true` | Wait for the listing file. |
| `WaitForTmp` | `false` | Wait for the Type3830 progress file. |
| `DetectionTimeout` | 5 minutes | Detection deadline; `null` means unlimited. |
| `ExtraDelay` | Zero | Additional delay after detection. |
| `PollInterval` | 100 milliseconds | Native monitoring poll interval. |
| `WatchLog` | `true` | Monitor native log messages. |
| `WatchTmp` | `false` | Monitor Type3830 progress. |
| `WatchTimeout` | `null` | Optional monitoring deadline. |
| `StallTimeout` | `null` | Optional stalled-progress deadline. |
| `CleanOnSuccess` | `false` | Enable native cleanup after success. |
| `KillOnTimeout` | `false` | Terminate TRNSYS on timeout. |
| `KillOnStall` | `false` | Terminate TRNSYS on a detected stall. |
| `Severity` | `LogSeverity.Notice` | Native log severity threshold. |
| `WriteEvents` | `false` | Enable native event-file output. |

Use the constructor's `trnRunQueuePath` to override the bundled queue separately
from `SimulationConfig.TrnRunPath`. Supply paths as ordinary strings without
embedded shell quotes; the client constructs native arguments and JSON requests.

## Manual integration follow-up

The initial migration intentionally adds no automated .NET tests. With the SDK
and TRNSYS available, manually build and pack, run one deck and a concurrent
batch, check Type3830 progress, failures and logs, and verify that explicit
shutdown drains accepted work without leaving queue/runner processes behind.
Also install the `.nupkg` into a separate `net10.0-windows` application and check
native asset discovery in both its build and `win-x64` publish output. The
project-reference examples alone do not exercise NuGet asset selection.

These are follow-up instructions, not a statement that validation has run.
