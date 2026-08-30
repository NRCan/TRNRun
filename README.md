# TRNRun

TRNRun is a tool for running [TRNSYS](https://www.trnsys.com/) simulations, built to make batch runs easy to automate, monitor, and orchestrate.

## Components

| Component                 | Description                                                                                                                                                                     |
| ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [Type3830](type3830/)     | Custom TRNSYS component that periodically writes simulation `TIME`, `START`, `STOP`, and `STEP` to a `***.tmp` file.                                                           |
| [TRNRun CLI](trnrun/)     | `trnrun.exe` launches a single deck, serializes TRNSYS startup machine-wide, monitors the run, and emits `STATUS` / `CONFIG` / `PROGRESS` / `LOG` events as JSON Lines on stdout. |
| [TRNRun manager](manager/) | `trnrun` Python package runs many decks at once (up to a set limit), with a thread-safe API and a live terminal display.                                                        |

## Requirements

- Windows
- Python >= 3.12
- TRNSYS v17 or v18
- _Optional: Progress Tracker (Type3830)_

## Installation

```sh
pip install trnrun
```

## Usage
```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager() as manager:
    manager.add("path/to/deck.dck", config)
    manager.wait()
```

## Demo

https://github.com/user-attachments/assets/a3599f98-c011-4ccd-8f6d-2f819b6f493d



## License

MIT License - see LICENSE file for details.
