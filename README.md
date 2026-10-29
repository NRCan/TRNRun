<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="./assets/trnrun-black.svg">
    <img alt="TRNRun" src="./assets/trnrun-black.svg">
  </picture>
</p>

-----------------

<p align="center">
  <a href="https://github.com/NRCan/TRNRun/actions/workflows/build.yml"><img alt="Unit Tests" src="https://img.shields.io/github/actions/workflow/status/NRCan/TRNRun/build.yml?branch=main&label=Unit%20Tests"></a>
  <a href="https://www.trnsys.com/"><img alt="TRNSYS 17 / 18" src="https://img.shields.io/badge/TRNSYS-17%20%7C%2018-yellow"></a>
  <a href="LICENSE"><img alt="License - MIT" src="https://img.shields.io/badge/license-MIT-blue.svg"></a>
</p>

TRNRun is a tool for running [TRNSYS](https://www.trnsys.com/) simulations,
designed to make batch runs easy to automate, monitor, and orchestrate from
Python, MATLAB, .NET, or the command line.

<table>
  <tr>
    <th width="33%">TRNRun Runner</th>
    <th width="33%">Terminal Display</th>
    <th width="33%">GUI</th>
  </tr>
  <tr>
    <td><video src="https://github.com/user-attachments/assets/b5e91df8-a9dc-4add-9117-24786cb10db9"></video></td>
    <td><video src="https://github.com/user-attachments/assets/b94c493f-0c1c-42a6-b559-b17b61d1612b"></video></td>
    <td><video src="https://github.com/user-attachments/assets/9ece228e-33aa-48f3-a872-dce78c1dc777"></video></td>
  </tr>
</table>

## Components

| Component                            | Role                                                            |
| ------------------------------------ | --------------------------------------------------------------- |
| [TRNRun Runner](components/trnrun/)  | Runs and monitors one deck, emitting JSON Lines events.         |
| [TRNRun Daemon](components/trnrund/) | Queues and tracks simulations for one client over a JSON pipe.  |
| [Type3830](components/type3830/)     | Reports simulation progress for monitoring and stall detection. |

## Libraries

| Library                     | Release                                                                                                                                                      | Compatibility                                                                                                             | Install                                                                          |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| [Python](libraries/python/) | [![PyPI Latest Release](https://img.shields.io/pypi/v/trnrun.svg?color=blue)](https://pypi.org/project/trnrun/)                                              | [![Python versions](https://img.shields.io/pypi/pyversions/trnrun.svg)](https://pypi.org/project/trnrun/)                 | `pip install trnrun` or `uv add trnrun`                                          |
| [.NET](libraries/dotnet/)   |  [![NuGet Latest Release](https://img.shields.io/nuget/v/TRNRun.svg?color=512BD4)](https://www.nuget.org/packages/TRNRun)                             | [![.NET 10](https://img.shields.io/badge/.NET-10-512BD4)](https://dotnet.microsoft.com/download/dotnet/10.0)              | `dotnet add package TRNRun`                                                      |
| [MATLAB](libraries/matlab/) | [![MATLAB Toolbox Latest Release](https://img.shields.io/github/v/release/NRCan/TRNRun?label=toolbox&color=e16737)](https://github.com/NRCan/TRNRun/releases/latest) | [![MATLAB R2021a+](https://img.shields.io/badge/MATLAB-R2021a%2B-e16737)](https://www.mathworks.com/products/matlab.html) | `.mltbx` from [GitHub Releases](https://github.com/NRCan/TRNRun/releases/latest) |



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
