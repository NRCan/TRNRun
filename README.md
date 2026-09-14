<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="./assets/TRNRUN_White.svg">
    <source media="(prefers-color-scheme: light)" srcset="./assets/TRNRUN_Black.svg">
    <img alt="TRNRun Logo" src="./assets/TRNRUN_Black.svg">
  </picture>
</p>

# TRNRun

TRNRun is a tool for running [TRNSYS](https://www.trnsys.com/) simulations, built to make batch runs easy to automate, monitor, and orchestrate.

## Nim components and packages

| Component | Description |
| --- | --- |
| [Type3830](components/type3830/) | Custom TRNSYS component that periodically writes simulation `TIME`, `START`, `STOP`, and `STEP` to a `***.tmp` file. |
| [TRNRun CLI](components/trnrun/) | `trnrun.exe` launches a single deck, serializes TRNSYS startup machine-wide, monitors the run, and emits `STATUS` / `CONFIG` / `PROGRESS` / `LOG` events as JSON Lines on stdout. |
| [TRNRun Queue](components/trnrunq/) | `trnrunq.exe` accepts JSON Lines requests on stdin, runs `trnrun.exe` with bounded concurrency, and merges runner output onto stdout. |

## Libraries

| Library | Description |
| --- | --- |
| [Python](libraries/python/) | `trnrun` Python package runs many decks at once with bounded concurrency, a thread-safe API, and a live terminal display. |
| [MATLAB](libraries/matlab/) | TRNRun MATLAB toolbox submits and monitors concurrent simulations through the bundled runner and queue executables. |

## Requirements

- Windows x64
- TRNSYS 17 or 18
- Python 3.12 or newer for the Python package
- MATLAB R2021a or newer for the MATLAB toolbox (provisional release floor)
- Optional: Progress Tracker (Type3830)

## Installation

### Python

```sh
pip install trnrun
```

### MATLAB

Open the released `trnrun-v<version>-win_amd64.mltbx` file in MATLAB. See the
[MATLAB library documentation](libraries/matlab/) for source-checkout and
packaging instructions.

## Usage

### Python

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager() as manager:
    manager.add("path/to/deck.dck", config)
    manager.wait()
```

### MATLAB

```matlab
config = trnrun.SimulationConfig(watch_tmp=true);
manager = trnrun.SimulationManager();

simulation = manager.add("path/to/deck.dck", config);
manager.wait(simulation);
manager.shutdown();
```

## Demo

https://github.com/user-attachments/assets/a3599f98-c011-4ccd-8f6d-2f819b6f493d

## License

MIT License - see LICENSE file for details.
