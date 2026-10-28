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

<table>
  <tr>
    <th width="33%">Python</th>
    <th width="33%">Runner</th>
    <th width="33%">.NET</th>
  </tr>
  <tr>
    <td><video src="PYTHON_VIDEO_URL"></video></td>
    <td><video src="RUNNER_VIDEO_URL"></video></td>
    <td><video src="DOTNET_VIDEO_URL"></video></td>
  </tr>
</table>

## Components

| Component                            | Role                                                            |
| ------------------------------------ | --------------------------------------------------------------- |
| [TRNRun Runner](components/trnrun/)  | Runs and monitors one deck, emitting JSON Lines events.         |
| [TRNRun Daemon](components/trnrund/) | Queues and tracks simulations for one client over a JSON pipe.  |
| [Type3830](components/type3830/)     | Reports simulation progress for monitoring and stall detection. |

## Libraries

| Library                     | Install                                                                          | Requires       |
| --------------------------- | -------------------------------------------------------------------------------- | -------------- |
| [Python](libraries/python/) | `pip install trnrun` or `uv add trnrun`                                          | Python 3.12+   |
| [MATLAB](libraries/matlab/) | `.mltbx` from [GitHub Releases](https://github.com/NRCan/TRNRun/releases/latest) | MATLAB R2021a+ |
| [.NET](libraries/dotnet/)   | `dotnet add package TRNRun`                                                      | .NET 10        |

Each library runs concurrent simulation batches through the bundled daemon.

## Requirements

- Windows x64
- TRNSYS 17 or 18
- Optional: the [Type3830 Progress Tracker](components/type3830/) in each deck
  for progress reporting

## Quick start

### Python

```python
from trnrun import SimulationManager

with SimulationManager(workers=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", watch_tmp=True)
    manager.wait(simulation)
```

See the [Python documentation](libraries/python/) for more details.

### MATLAB

```matlab
import trnrun.*
manager = SimulationManager(workers=1);

simulation = manager.add("C:\path\to\deck.dck", ...
    SimulationSettings(watchTmp=true), waitFor="FINISHED");
```

See the [MATLAB documentation](libraries/matlab/) for more details.

### .NET

```csharp
using TRNRun;

await using TRNRunDaemon daemon = await TRNRunDaemon.StartAsync(workers: 1);
long simId = await daemon.AddAsync(@"C:\path\to\deck.dck", new SimulationSettings { WatchTmp = true });
Simulation simulation = await daemon.WaitForFinishedAsync(simId);
```

See the [.NET documentation](libraries/dotnet/) for more details.

## License

TRNRun is available under the [MIT License](LICENSE).
