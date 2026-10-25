# TRNRun for .NET

Run TRNSYS simulations from .NET through
[`trnrund`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund), which
the package bundles with `trnrun.exe`. `TRNRunDaemon` is a thin client: one
async method per trnrund command, returning simulations as typed `Simulation`
records. Queuing policy and display are yours to build on top.

Requires Windows x64, .NET 10 (`net10.0`; the assembly is marked Windows-only),
and TRNSYS 17 or 18 for real runs. No NuGet dependencies; trim- and
AOT-compatible.

```csharp
using TRNRun;

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 4);
long simId = await daemon.AddAsync("building-a.dck", new SimulationSettings { GuiVisibility = GuiVisibility.Minimized }, label: "a");

Simulation sim = await daemon.WaitForFinishedAsync(simId);
Console.WriteLine($"{sim.Status} {sim.Succeeded} {sim.Warnings} warnings");
await daemon.ReleaseAsync(simId); // trnrund forgets it
```

## TRNRunDaemon

| Member | trnrund command |
| --- | --- |
| `TRNRunDaemon.StartAsync(workers, trnrundPath, trnrunPath)` | starts it, then `ready` |
| `AddAsync(deckFile, settings, label) -> long` | `add` |
| `GetSimulationAsync(simId, withLogs) -> Simulation` | `simulation` |
| `GetSimulationsAsync(state, withLogs) -> IReadOnlyList<Simulation>` | `simulations` |
| `WaitForFinishedAsync(simId, pollInterval) -> Simulation` | `simulation`, polled until `Finished` |
| `CancelAsync(simId)` | `cancel`: `Queued` or `Running` only |
| `ReleaseAsync(simId)` | `release`: `Finished` only |
| `RequestAsync(JsonObject) -> JsonObject` | any raw request |

`workers` defaults to trnrund's, the CPU count minus one. `trnrundPath` and
`trnrunPath` default to the executables the package copies to `native/` beside
your application. Relative deck and TrnEXE paths resolve from the current
directory.

Requests are thread-safe: they take turns on the one pipe. A
`CancellationToken` only cancels the wait for an earlier request; a request
already sent runs to its reply, so the pipe never gets out of step. Disposing
waits for the request in progress, then closes trnrund's stdin, so it kills
every unfinished run and exits; waiting and later calls throw
`ObjectDisposedException`. Prefer `await using`: `Dispose` blocks while
trnrund exits.

## Records

`Simulation` holds trnrund's
[simulation fields](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#simulation-fields)
in PascalCase, except `trnrunStatus` and `trnrunMessage`, which are `Status`
and `StatusMessage`. `State` and `Status` are the `SimulationState` and
`SimulationStatus` enums; progress (`SimTime`, `Percent`, and `Elapsed` and
`Eta` as `TimeSpan`s) and config (`StartTime`, `StopTime`, `TimeStep`) are `null` until TRNRun
reports them; `Logs` are `LogEvent` records, empty unless asked for with
`withLogs`; timestamps are UTC `DateTimeOffset`s; `Setting` is the raw
`JsonElement`. Each record is a snapshot: ask again for the current one.

`SimulationSettings` names and types every TRNRun option (`--help` of
`trnrun.exe`), with durations as `TimeSpan`s; a `null` property keeps TRNRun's
default, and `Timeout.InfiniteTimeSpan` means unlimited. trnrund checks the
values when the simulation is added; a missing `TrnexePath` throws
`FileNotFoundException` before. `Simulation.TrnrunArgs` holds the flags they
became.

## Errors

`RequestException` when trnrund refuses a request (missing deck, unknown
`simId`, releasing an unfinished run...), `DaemonExitedException` when it no
longer answers, with its exit code and stderr. Both derive from
`TRNRunException`, which is also thrown, wrapping the parse error, when a reply
breaks the protocol.

## Examples

Run from this directory, substituting real deck and TRNSYS paths:

```powershell
# One deck, printing progress and warnings; omit --progress if Type3830 is not in the deck. Ctrl+C interrupts it.
dotnet run --project examples/TRNRun.Example -- "C:\decks\model.dck" "C:\TRNSYS18\Exe\TrnEXE64.exe" --progress

# Every .dck file in a directory, two at a time, each reported (and released) as it finishes.
dotnet run --project examples/TRNRun.BatchExample -- "C:\decks" "C:\TRNSYS18\Exe\TrnEXE64.exe" 2
```

Both return `0` when every simulation succeeded, `1` when one failed, and `2`
for usage errors. Only run independent decks concurrently; trnrund does not
isolate shared TRNSYS output files.

`examples/TRNRun.SimpleGuiExample` is the least a WPF window needs: it starts
trnrund when it opens, polls every simulation into a table twice a second,
shows a run's logs and cancels it from buttons on its row, and stops trnrund
when it closes. `examples/TRNRun.GuiExample` is a fuller window, optionally
given decks or deck directories on its command line; it polls only unfinished
runs and reads a run's logs only when its log counts grow.

```powershell
dotnet run --project examples/TRNRun.SimpleGuiExample
dotnet run --project examples/TRNRun.GuiExample -- "C:\decks"
```

## Development

```powershell
just trnrun-bin; just trnrund-bin
dotnet test TRNRun.slnx
```

Tests run the real `trnrund.exe` with `TRNRun.FakeTrnrun` as the runner, so
they do not need TRNSYS.
