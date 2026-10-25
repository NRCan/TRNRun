# TRNRun for .NET

Run TRNSYS simulations from .NET through
[`trnrund`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund), which
the package bundles with `trnrun.exe`. `Daemon` is a thin client: one async
method per trnrund command, returning simulations as typed `Simulation`
records. Queuing policy, polling, and display are yours to build on top.

Requires Windows x64, .NET 10 (`net10.0-windows`), and TRNSYS 17 or 18 for real
runs. No NuGet dependencies; trim- and AOT-compatible.

```csharp
using TRNRun;

using Daemon daemon = await Daemon.StartAsync(workers: 4);
long simId = await daemon.AddAsync("building-a.dck", new SimulationSettings { GuiVisibility = GuiVisibility.Minimized }, label: "a");

Simulation sim = await daemon.SimulationAsync(simId);
while (sim.State != SimulationState.Finished)
{
    await Task.Delay(500);
    sim = await daemon.SimulationAsync(simId);
}

Console.WriteLine($"{sim.Status} {sim.Succeeded} {sim.Warnings} warnings");
await daemon.ReleaseAsync(simId); // trnrund forgets it
```

## Daemon

| Member | trnrund command |
| --- | --- |
| `Daemon.StartAsync(workers, trnrundPath, trnrunPath)` | starts it, then `ready` |
| `AddAsync(deckFile, settings, label) -> long` | `add` |
| `SimulationAsync(simId, withLogs) -> Simulation` | `simulation` |
| `SimulationsAsync(state, withLogs) -> IReadOnlyList<Simulation>` | `simulations` |
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
closes trnrund's stdin, so it kills every unfinished run and exits; later calls
throw `ObjectDisposedException`.

## Records

`Simulation` holds trnrund's
[simulation fields](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#simulation-fields)
in PascalCase, except `trnrunStatus` and `trnrunMessage`, which are `Status`
and `StatusMessage`. `State` and `Status` are the `SimulationState` and
`SimulationStatus` enums; progress (`SimTime`, `Percent`, `ElapsedMs`, `EtaMs`)
and config (`StartTime`, `StopTime`, `TimeStep`) are `null` until TRNRun
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
`simId`, cancelling a finished run...), `DaemonExitedException` when it no
longer answers, with its exit code and stderr. Both derive from
`TrnrunException`.

## Development

```powershell
just trnrun-bin; just trnrund-bin
dotnet test TRNRun.slnx
```

Tests run the real `trnrund.exe` with `TRNRun.FakeTrnrun` as the runner, so
they do not need TRNSYS.
