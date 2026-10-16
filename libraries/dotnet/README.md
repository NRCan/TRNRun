# TRNRun for .NET

Run and monitor TRNSYS simulations from C# using the existing native
`trnrun.exe` runner and `trnrunq.exe` queue. The queue owns scheduling and
concurrency; the .NET library exposes synchronous operations backed by a dedicated
queue reader thread, with no third-party runtime package dependencies.

## Requirements

- Windows x64 and .NET 10; target `net10.0-windows` in the consuming application.
- An installed, licensed TRNSYS 17 or 18. TRNSYS itself is not bundled.
- Optional [Type3830](https://github.com/NRCan/TRNRun/tree/main/components/type3830)
  in each deck for simulation progress and stall detection. Enable `WatchTmp`
  when using it; neither Type3830 nor TRNSYS is installed by this package.

NuGet packages include both native executables under `native/` and copy them
to that directory beside the application. No separate native download, Python
installation, or Nim installation is needed by package consumers. Framework-dependent
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
| `components/trnrun/build/trnrun.exe` | `native/trnrun.exe` |
| `components/trnrunq/build/trnrunq.exe` | `native/trnrunq.exe` |

There is no checked-in binary, placeholder, staged duplicate, or automatic
executable download. A managed build fails with instructions to run
`just dotnet-native` if either output is missing. Project-reference builds and
NuGet consumers copy both executables to `native/` beneath the application's
build and publish directories. The package's `buildTransitive/TRNRun.targets`
keeps this layout for direct and transitive NuGet consumers.

Bundled executable paths resolve only against `AppContext.BaseDirectory/native/`,
not the working directory, assembly location, or older runtime/flat layouts.
Keep the `native/` directory when deploying, including with single-file publish:
the child executables remain external files. For custom locations, set
`TrnRunPath` and the manager's `trnRunQueuePath` explicitly.

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
using var manager = new SimulationManager(
    maxConcurrent: 1,
    refreshInterval: TimeSpan.FromSeconds(1))
{
    ShowProgress = true
};

Simulation simulation = manager.Add(@"C:\decks\example.dck", config);
manager.Wait(simulation); // Complete desired work before disposal terminates the queue.
SimulationSnapshot snapshot = simulation.Snapshot();
Console.WriteLine($"{snapshot.DeckPath}: {snapshot.Status?.Status.ToString() ?? "unknown"}");
Console.WriteLine($"Succeeded: {snapshot.Succeeded}");
foreach (var log in simulation.Logs)
{
    Console.WriteLine(log);
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

- `examples/TRNRun.Example/Program.cs` uses `Add()` and `Wait(simulation)`, reads
  final status and progress from `Snapshot()`, prints logs, and optionally enables
  the console display.
- `examples/TRNRun.BatchExample/Program.cs` submits with `Add(blocking: false)`,
  captures `Submitted` handles, observes `Follow()` through snapshots, and calls
  `Wait()` before printing final snapshots, success/failure totals, and failed-run
  logs. Concurrency defaults to four when the last argument is omitted. It does
  not require Type3830 or enable `WatchTmp` by default.
- Both use `using` for manager cleanup and wait for desired work before disposal.
  They return `0` for successful simulations, `1` for completed simulation failures,
  and `2` for usage errors. Unexpected exceptions propagate with a nonzero process
  exit code.

Only use independent decks/output files concurrently; the queue does not
isolate shared TRNSYS output files for you.

## Manager API and lifecycle

```csharp
public SimulationManager(
    int? maxConcurrent = null,
    TimeSpan? refreshInterval = null,
    string? trnRunQueuePath = null);

// SimulationManager implements IDisposable.
public bool ShowProgress { get; set; } // Default: false; thread-safe.
public event Action<Simulation, TrnRunEvent>? SimulationUpdated;
public Simulation Add(string deckPath, SimulationConfig config, bool blocking = true);
public void Wait(Simulation? simulation = null);
public IEnumerable<Simulation> Follow(Simulation? simulation = null);
public void Shutdown();
public void Dispose();
```

- Default concurrency is `Math.Max(Environment.ProcessorCount - 1, 1)`; the
  existing constructor parameters are unchanged.
- `Add()` defaults to `blocking: true` and waits for native `QUEUE/ACCEPTED`: a
  worker has picked up the request. It can block while workers are occupied.
  `Add(deckPath, config, blocking: false)` returns the submitted handle after
  synchronously writing the request, without waiting for acceptance. A full stdin
  pipe can still block the write. Acceptance does not imply simulation success.
  The reader updates all runs independently of either call.
- `Submitted` returns all submitted handles in submission order, including those
  pending acceptance. Failed sends that were not accepted are removed.
  `Simulations` contains accepted runs in submission order. `Active` contains all
  unfinished submitted runs, including pending ones. `Succeeded` and `Failed`
  retain their meanings: finished successful and finished unsuccessful runs.
  These collections are copies containing live `Simulation` objects.
- `Wait(simulation)` waits for one owned run; `Wait()` waits for **all submitted
  runs**, including pending acceptance. Waiting uses a condition, not pipe reads.
  Already finished runs return immediately. Neither call shuts down the queue,
  so further submissions are possible afterward.
- `Follow(simulation)` or `Follow()` remains an `IEnumerable<Simulation>` observer
  yielding live objects, not immutable snapshots. It does not replay past updates
  and coalesces intervening updates per simulation for slow consumers. Validation
  occurs when enumeration starts. A selected simulation for `Wait` or `Follow`
  must belong to this manager. Malformed event lines are skipped, with a debug
  diagnostic.
- Reader EOF or failure wakes blocked operations. If the requested acceptance or
  completion is incomplete, it throws `IOException`; no success, failure, or
  completion outcome is synthesized. Waiting and observing never take over pipe
  reading from the reader thread.
- `SimulationUpdated` runs on the queue reader thread after state is updated and
  **outside the manager lock**. Each handler's exceptions are isolated from other
  handlers and the reader, with a debug diagnostic. Keep handlers prompt: do not
  call `Add` (even with `blocking: false`), `Wait`, `Follow`, `Shutdown`, or `Dispose`
  from a callback. These operations are rejected on the reader thread because
  they can block output consumption. Slow handlers delay subsequent queue reads.
- `Shutdown()` and `Dispose()` mark the manager closed, wake waiters, and terminate
  the queue/process tree using best-effort Windows Job Object protection and
  bounded five-second waits with retry. They **do not drain work**: call `Wait`
  first to complete desired simulations. Incomplete simulations remain incomplete;
  cleanup does not fabricate outcomes. Repeated successful shutdown is a no-op;
  failed cleanup can be retried. New work is not allowed after closure.
- `SimulationManager : IDisposable` supports `using` statements; `Dispose()`
  performs shutdown. The owner must not run shutdown/disposal concurrently,
  reentrantly, or from a callback. Do not rely on garbage collection for cleanup.
  The Job Object is best-effort protection against orphaned children, not a
  substitute for explicit cleanup. There are no asynchronous APIs or
  `IAsyncDisposable` support.

### Following updates yourself

For the manager and simulation created above, observe updates before the final
`Wait(simulation)` and snapshot reads:

```csharp
manager.ShowProgress = false;
foreach (Simulation updated in manager.Follow(simulation))
{
    SimulationSnapshot snapshot = updated.Snapshot();
    Console.WriteLine($"{snapshot.Id}: {snapshot.Status}; progress: {snapshot.Progress}");
}
```

Breaking out or pausing enumeration does not stop the reader or the simulation.
A later `Follow()` observes future updates, not a replay of missed ones. Use
`Wait()` to ensure desired work completes before shutdown/disposal, even if you
stop observing early. Take a final snapshot after waiting because `Follow()` may
miss updates that occurred before enumeration began.

### Threading, UI integration, and console output

A dedicated queue reader advances state even while the caller is idle, waiting,
or paused in `Follow()`. Individual simulation reads are locked; use `Snapshot()`
for a consistent multi-property view. For UI code, read snapshots on the UI thread
or subscribe to `SimulationUpdated`, capture a snapshot in the handler, and
marshal it to the UI with a nonblocking post. Do not update UI controls directly
from the reader thread or synchronously invoke the UI thread from a handler.
Keep ownership of shutdown/disposal separate from observers and callbacks.

`ShowProgress` is a thread-safe public read/write property, defaulting to `false`.
Set it to `true` to opt into a basic `System.Console` display of deck, status, log
counts, elapsed time, ETA, and available simulation progress. The constructor's
`refreshInterval` throttles **rendering only**. It is not a polling interval,
background timer, or state-update frequency, and there is no separate display
refresh property. Native polling is configured by `SimulationConfig.PollInterval`.
The client adds no timers, asynchronous APIs, or third-party runtime dependencies.

## Simulation state

| Property | Meaning |
| --- | --- |
| `Id` | Run identifier used to route native events. |
| `DeckPath` | Submitted deck path. |
| `Config` | Immutable configuration submitted for this run. |
| `IsAccepted` | The queue has reported `QUEUE/ACCEPTED`. |
| `IsFinished` | The queue has reported `QUEUE/COMPLETED`, not just a terminal status or 100% progress. |
| `IsRunning`, `HasTerminalStatus` | Convenience views of the latest status; neither replaces `IsFinished`. |
| `Succeeded` | Finished, with the latest status equal to `SimulationStatus.Done`. |
| `Status` | Latest `StatusEvent`, including its typed `SimulationStatus`. |
| `Progress` | Latest progress event, if available; not a completion signal. |
| `ConfigEvent`, `SettingEvent` | Latest native simulation bounds and effective runner settings. |
| `CompletionEvent` | Native queue completion metadata, including its nullable `ExitCode`. |
| `Logs` | Stable copy of all retained native log entries, oldest first; retention is unbounded. |
| `LogCount`, `Notices`, `Warnings`, `Fatals` | Cumulative received counts. |

`Simulation` locks individual property reads. `Snapshot()` returns an immutable
sealed record, `SimulationSnapshot`, with a consistent view of `Id` (`string`),
`DeckPath` (`string`), `IsAccepted`, `IsFinished`, `Status` (`StatusEvent?`, preserving
its existing .NET type), `Progress`, `ConfigEvent`, `LogCount`, `Notices`, `Warnings`,
and `Fatals`, plus `IsRunning`, `Succeeded`, and `HasTerminalStatus`.

Snapshots never copy logs. Retrieve `simulation.Logs` separately when needed;
each access returns a stable copy, while all received logs remain retained without
a size limit. Detailed metadata such as `Config`, `SettingEvent`, and
`CompletionEvent` stays on `Simulation`, not the lightweight snapshot.

A finished simulation that did not succeed appears in `manager.Failed`.
Missing native status/progress/exit-code information is not synthesized. Reader
failure or shutdown alone does not make an incomplete simulation finished or
place it in either outcome collection.

## Configuration

`SimulationConfig` is an immutable record with init-only properties. Create a
new record (or use `with`) to change settings for future submissions; do not
mutate an accepted run's configuration. Durations use `TimeSpan`, and nullable
timeouts use `null` (or zero) for unlimited/disabled behavior. Durations must
be whole milliseconds from zero through 2,147,483,647 (about 24.8 days), with
`PollInterval` at least one millisecond. Invalid enum values and missing runner
or TRNSYS executable files are rejected before submission.

Like the Python manager, `SimulationManager.Add` checks that the deck exists,
then validates the configuration while building unquoted native arguments and
resolving the runner executable. Unsupported deck extensions are reported as
failed simulations by the native queue. A missing queue executable is reported
by process startup. The configuration is already immutable, so no copy is needed.
The queue supplies the deck path and run ID.

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

## Native layout check

After `just dotnet-native`, run from `libraries/dotnet/`:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File packaging/Test-NativeLayout.ps1
```

This dependency-free check packs the library and uses a temporary local NuGet
feed and isolated package cache. It verifies bundled and explicit executable
resolution from project-reference, direct NuGet, and transitive NuGet consumers
in build and publish output, including single-file publish. No TRNSYS simulation
is launched. Temporary consumer projects and packages are removed afterward.

## Manual integration follow-up

With TRNSYS available, run one deck and a nonblocking concurrent batch, check
Type3830 progress, snapshots, failures and logs, and verify that `Wait()` completes
all submitted work, including pending acceptance. Check that pausing or breaking
`Follow()` leaves the reader running and that prompt callbacks can post snapshots
to a UI. Separately verify that shutdown/disposal terminates remaining work with
bounded waits, leaves incomplete simulations incomplete, supports repeated
successful cleanup, and does not leave queue/runner processes behind. Reader
EOF/failure should wake blocked operations with `IOException` when their requested
work is incomplete. The layout check does not exercise simulation behavior.
