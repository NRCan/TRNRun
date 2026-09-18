<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="./assets/trnrun-black.svg">
    <img alt="TRNRun" src="./assets/trnrun-black.svg">
  </picture>
</p>

TRNRun is a tool for running [TRNSYS](https://www.trnsys.com/) simulations,
designed to make batch runs easy to automate, monitor, and orchestrate from
Python, MATLAB, or the command line.

## Components

| Component                           | Role                                                                  |
| ----------------------------------- | --------------------------------------------------------------------- |
| [TRNRun Runner](components/trnrun/) | Runs and monitors one deck, emitting JSON Lines events.               |
| [TRNRun Queue](components/trnrunq/) | Runs multiple decks with bounded concurrency and merges their events. |
| [Type3830](components/type3830/)    | Reports simulation progress for monitoring and stall detection.       |

## Libraries

| Client                      | Role                                                        |
| --------------------------- | ----------------------------------------------------------- |
| [Python](libraries/python/) | Python interface for running concurrent simulation batches. |
| [MATLAB](libraries/matlab/) | MATLAB interface for running concurrent simulation batches. |

Both libraries bundle the `trnrun` and `trnrunq` executables.

## Requirements

- Windows x64
- TRNSYS 17 or 18
- Python 3.12 or newer for the Python library
- MATLAB R2021a or newer for the MATLAB library

Progress reporting requires the optional
[Type3830 Progress Tracker](components/type3830/) in each deck.

## Python quick start

Install the package with pip:

```powershell
pip install trnrun
```

Or with uv:

```powershell
uv add trnrun
```

Run a deck:

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager() as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", config)
    manager.wait()
```

See the [Python documentation](libraries/python/) for concurrent batches,
monitoring, and configuration.

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

## Demo

https://github.com/user-attachments/assets/389631b0-c986-4733-9cee-1efe2100246e

## License

TRNRun is available under the [MIT License](LICENSE).
