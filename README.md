# TRNRun

TRNRun is a tool for running [TRNSYS](https://www.trnsys.com/) simulations, built to make batch runs easy to automate, monitor, and orchestrate.

## NIM components and packages

| Component | Description |
| --- | --- |
| [Type3830](components/type3830/) | Optional custom TRNSYS component that periodically writes simulation `TIME`, `START`, `STOP`, and `STEP` to a `***.tmp` file for progress and stall monitoring. |
| [TRNRun CLI](components/trnrun/) | `trnrun.exe` launches a single deck, serializes TRNSYS startup machine-wide, monitors the run, and emits `STATUS` / `CONFIG` / `PROGRESS` / `LOG` events as JSON Lines on stdout. |
| [TRNRun Queue](components/trnrunq/) | `trnrunq.exe` accepts JSON Lines requests on stdin, runs `trnrun.exe` with bounded concurrency, and merges runner output onto stdout. |

## Client libraries

| Client | Description |
| --- | --- |
| [Python](libraries/python/) | `trnrun` Python package for synchronous batch submission, monitoring, and result inspection with a live terminal display. |
| [MATLAB](libraries/matlab/) | Native MATLAB API for synchronous batch submission, monitoring, callbacks, and result inspection without Python or additional MATLAB toolboxes. MATLAB R2021a is the provisional release floor. |

Each manager owns its own `trnrunq.exe` process. The queue manages concurrent
native runners, but client state is pumped synchronously by `add`, `wait`, and
`follow`. Client managers are single-threaded and are not thread-safe. Long
pauses between manager calls or slow MATLAB callbacks can apply backpressure
and stall queue progress.

## Requirements

Shared runtime requirements:

- Windows x64
- TRNSYS v17 or v18
- Optional: Progress Tracker (Type3830) for progress and stall monitoring

Client-specific requirements:

- Python client: Python >= 3.12
- MATLAB client: MATLAB R2021a or newer as a provisional target; no Python or
  additional MATLAB toolboxes

The MATLAB release floor and runtime behavior have not been verified by
execution as part of this documentation update.

## Installation

### Python

```sh
pip install trnrun
```

### MATLAB

Add only the MATLAB `toolbox` directory, not its package or subdirectories:

```matlab
addpath("C:\path\to\TRNRun\libraries\matlab\toolbox")
```

See the [MATLAB client README](libraries/matlab/) for lifecycle guidance,
Type3830 behavior, timeout interactions, and examples.

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
function simulation = run_deck(deck_path)
    addpath("C:\path\to\TRNRun\libraries\matlab\toolbox")

    config = trnrun.SimulationConfig(watch_tmp=false);
    manager = trnrun.SimulationManager(maxConcurrent=1);
    cleanup = onCleanup(@() delete(manager));

    simulation = manager.add(deck_path, config);
    manager.wait();
    manager.shutdown();
end
```

`shutdown()` drains submitted work normally. Function-scoped `onCleanup`
provides best-effort cleanup if an error or interruption prevents shutdown;
that fallback may terminate unfinished work owned by the manager.

## Demo

https://github.com/user-attachments/assets/a3599f98-c011-4ccd-8f6d-2f819b6f493d

## License

MIT License - see LICENSE file for details.
