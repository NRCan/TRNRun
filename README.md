<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="./assets/trnrun-black.svg">
    <img alt="TRNRun" src="./assets/trnrun-black.svg">
  </picture>
</p>

TRNRun is a tool for running [TRNSYS](https://www.trnsys.com/) simulations,
designed to make batch runs easy to automate, monitor, and orchestrate from
Python, MATLAB, .NET, or the command line.

## Components

| Component                            | Role                                                            |
| ------------------------------------ | --------------------------------------------------------------- |
| [TRNRun Runner](components/trnrun/)  | Runs and monitors one deck, emitting JSON Lines events.         |
| [TRNRun Daemon](components/trnrund/) | Queues and tracks simulations for one client over a JSON pipe.  |
| [Type3830](components/type3830/)     | Reports simulation progress for monitoring and stall detection. |

## Libraries

| Client                      | Role                                                        | Bundles             |
| --------------------------- | ----------------------------------------------------------- | ------------------- |
| [Python](libraries/python/) | Python interface for running concurrent simulation batches. | `trnrun`, `trnrund` |
| [MATLAB](libraries/matlab/) | MATLAB interface for running concurrent simulation batches. | `trnrun`, `trnrund` |
| [.NET](libraries/dotnet/)   | .NET interface for running concurrent simulation batches.   | `trnrun`, `trnrund` |

## Requirements

- Windows x64
- TRNSYS 17 or 18
- Python 3.12 or newer for the Python library
- MATLAB R2021a or newer for the MATLAB library
- .NET 10 for the .NET library

Progress reporting requires the optional
[Type3830 Progress Tracker](components/type3830/) in each deck.

## Python quick start

Install the package:

```powershell
pip install trnrun
```

Or with uv:

```powershell
uv add trnrun
```

Use `SimulationManager(display=False)` to run without the progress display.

Run a deck:

```python
from trnrun import SimulationManager

with SimulationManager(workers=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", watch_tmp=True)
    manager.wait(simulation)
```

See the [Python documentation](libraries/python/) for the thin `Daemon` client,
concurrent batches, settings, and custom displays.

## MATLAB quick start

Install the TRNRun toolbox from the MATLAB Add-On Explorer.

Run a deck:

```matlab
config = trnrun.SimulationConfig(watch_tmp=true);
manager = trnrun.SimulationManager();

simulation = manager.add("C:\path\to\deck.dck", config);
manager.wait();
manager.shutdown();
```

See the [MATLAB documentation](libraries/matlab/) for installation, concurrent
batches, and result inspection.

## .NET quick start

Install the package:

```powershell
dotnet add package TRNRun
```

Run a deck:

```csharp
using TRNRun;

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 1);
long simId = await daemon.AddAsync(@"C:\path\to\deck.dck", new SimulationSettings { WatchTmp = true });
Simulation simulation = await daemon.WaitForFinishedAsync(simId);
```

See the [.NET documentation](libraries/dotnet/) for concurrent batches,
progress polling, and settings.

## Demo

https://github.com/user-attachments/assets/389631b0-c986-4733-9cee-1efe2100246e

## License

TRNRun is available under the [MIT License](LICENSE).
