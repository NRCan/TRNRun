# TRNRun
`trnrun` is a Python package that drives the TRNRun runner (`trnrun.exe`) to launch, monitor, and
manage TRNSYS simulations from Python. It runs multiple decks concurrently through a bounded worker
pool, mirrors each run's status, progress, and log events behind thread-safe objects, and renders a
live terminal display while simulations run, making it suitable for batch studies, parametric runs,
and job orchestration.

Each simulation is executed by its own `trnrun.exe` process, which handles machine-wide launch
serialization, startup detection, runtime monitoring, and log parsing on its own (see the runner
documentation). The manager consumes the runner's line-delimited JSON output from stdout and exposes
it through a typed, thread-safe Python API.

## Requirements

- Windows
- Python >= 3.12
- TRNSYS v17 or v18
- _Optional: Progress Tracker (Type3830)_

## Dependencies

- [Rich](https://github.com/Textualize/rich)

## Installation

PyPI:

```sh
pip install trnrun
```

## Quick start

Run a single deck:

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager() as manager:
    manager.add("path/to/deck.dck", config)
    manager.wait()
```

or

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)
manager = SimulationManager()

manager.add("path/to/deck.dck", config)
manager.wait()
```

Run a folder of decks with bounded concurrency:

```python
from pathlib import Path
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=4) as manager:
    for deck in sorted(Path(r"C:\path\to\dck").glob("*.dck")):
        manager.add(deck, config)

    manager.wait()

    print(f"succeeded: {len(manager.succeeded)}  failed: {len(manager.failed)}")
```

Do your own results aggregation:

```python
import time

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(refresh_interval=0, block=False) as manager:  # 0 disables the built-in display
    sim = manager.add("example.dck", config)

    while not sim.is_finished:
        snap = sim.snapshot()
        if snap.progress is not None:
            print(f"{snap.progress.percent:6.1%}  (N:{snap.notices} W:{snap.warnings} F:{snap.fatals})", end="\r")
        time.sleep(1.0)

    print(f"\nexit code: {sim.exit_code}  succeeded: {sim.succeeded}")
```

## API reference

### Simulation states

Reported through `Simulation.status`:

| Status      | Meaning                                                                      |
| ----------- | ---------------------------------------------------------------------------- |
| `PENDING`   | Waiting to acquire the global mutex.                                         |
| `LAUNCHING` | Mutex acquired; TrnEXE is being started.                                     |
| `RUNNING`   | Startup detection passed; the simulation is being monitored.                 |
| `DONE`      | Completed successfully.                                                      |
| `CANCELLED` | The process exited before simulation time reached 100 %.                     |
| `ERROR`     | Failed to launch, died during startup, or logged a fatal error.              |
| `TIMEOUT`   | Exceeded `watch_timeout_ms` (or `detect_timeout_ms` with `kill_on_timeout`). |
| `STALLED`   | Simulation time stopped advancing for longer than `stall_timeout_ms`.        |

> `CANCELLED` and `STALLED` require `watch_tmp=True` (Type3830), since both are derived from
> simulation progress. Without it, an early exit is reported as `DONE`.

### SimulationManager

Runs simulations using a bounded pool of worker threads.

```python
SimulationManager(max_concurrent=DEFAULT_MAX_CONCURRENT, refresh_interval=1.0, block=True)
```

| Parameter          | Type    | Default           | Description                                                                             |
| ------------------ | ------- | ----------------- | --------------------------------------------------------------------------------------- |
| `max_concurrent`   | `int`   | `cpu_count() - 1` | Maximum number of simulations running at the same time. Must be >= 1.                   |
| `refresh_interval` | `float` | `1.0`             | Seconds between terminal display updates. A value <= 0 disables the display.            |
| `block`            | `bool`  | `True`            | If `True`, `add()` blocks until a worker is available; if `False`, returns immediately. |

| Member                              | Description                                                                                                                                                          |
| ----------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `add(deck_file, config)`            | Start a simulation as soon as a worker is available and return its `Simulation`.                                                                                     |
| `wait(timeout=None)`                | Block until every simulation added _before this call_ has finished, or the timeout (seconds) expires. Returns `True` if all of them finished.                        |
| `simulations`                       | All added simulations, in creation order.                                                                                                                            |
| `succeeded()`                       | Simulations that completed successfully.                                                                                                                             |
| `failed()`                          | Simulations that finished without succeeding (fatal errors, non-zero exit, cancellation, launch failure).                                                            |
| `cancel()`                          | Request cancellation of every added simulation.                                                                                                                      |
| `shutdown(cancel=False, wait=True)` | Close the manager; further `add()` calls raise. With `cancel=True` running simulations are cancelled first; with `wait=True` the call blocks until the workers exit. |

`SimulationManager` is a context manager. Leaving the `with` block calls `shutdown()`, which waits
for running simulations to finish

### Simulation

A handle for one runner process, normally obtained from `SimulationManager.add()`. TRNRun owns the
simulation state; this object only mirrors the latest events received on stdout, plus local process
bookkeeping (PID, exit code, cancellation).

All members are thread-safe. Each property acquires the internal lock separately, so two
consecutive reads may straddle an event - use `snapshot()` whenever a consistent multi-field view
is required.

| Member                          | Type                    | Description                                                                                 |
| ------------------------------- | ----------------------- | ------------------------------------------------------------------------------------------- |
| `id`                            | `int \| None`           | Identifier assigned by the manager.                                                         |
| `deck_path`                     | `str\| Path             | Deck (`.dck`) file passed to the runner.                                                    |
| `status`                        | `StatusEvent \| None`   | Latest `STATUS` event.                                                                      |
| `progress`                      | `ProgressEvent \| None` | Latest `PROGRESS` event. Requires `watch_tmp=True`.                                         |
| `config`                        | `ConfigEvent \| None`   | `CONFIG` event with simulation start / stop / step.                                         |
| `logs`                          | `list[LogEvent]`        | Rolling window of `LOG` events (default: last 5 000).                                       |
| `notices`, `warnings`, `fatals` | `int`                   | Event counters, kept over the whole run — even after older events leave the rolling window. |
| `exit_code`                     | `int \| None`           | `None` while running; the runner exit code afterwards.                                      |
| `error`                         | `str \| None`           | Python-side failure description (spawn failure, cancelled before start, ...).               |
| `cancelled`                     | `bool`                  | Whether `cancel()` was requested.                                                           |
| `pid`                           | `int \| None`           | Runner process ID.                                                                          |
| `is_running`                    | `bool`                  | Runner process is alive.                                                                    |
| `is_finished`                   | `bool`                  | An exit code has been recorded.                                                             |
| `succeeded`                     | `bool`                  | Success criteria under [Exit codes](#exit-codes).                                           |
| `snapshot()`                    | `SimulationSnapshot`    | Consistent view of all of the above, captured under a single lock.                          |
| `cancel()`                      | `None`                  | Request termination of the runner process. Safe to call before or after start.              |
| `run()`                         | `None`                  | Spawn the runner and consume stdout until it exits. Called by the manager's worker thread   |

### SimulationSnapshot

Frozen dataclass returned by `Simulation.snapshot()` with the fields `id`, `deck_path`, `status`,
`progress`, `config_event`, `notices`, `warnings`, `fatals`, `log_count`, `exit_code`, `error`,
and `cancelled`. Every field is captured in one critical section, so a consumer can never mix
state from either side of an event.

### SimulationConfig

Dataclass describing how the runner is invoked. Each field maps to a `trnrun.exe` flag (passed as
`--name:value`), and the defaults mirror the runner's own CLI defaults. See the runner
documentation for full flag semantics.

| Field               | Runner flag       | Default                        | Description                                                            |
| ------------------- | ----------------- | ------------------------------ | ---------------------------------------------------------------------- |
| `trnrun_path`       | —                 | bundled `trnrun.exe`           | Runner executable to invoke.                                           |
| `trnexe_path`       | `--trnexePath`    | `C:\TRNSYS18\Exe\TrnEXE64.exe` | TRNSYS executable (`TrnEXE64.exe` / `TrnEXE.exe`).                     |
| `gui_visibility`    | `--guiVisibility` | `"hidden"`                     | TRNSYS window behavior: `keep`, `auto`, `min`, `minAuto`, `hidden`.    |
| `wait_for_gui`      | `--waitForGui`    | `True`                         | Launch detection: wait for a TRNSYS GUI.                               |
| `wait_for_lst`      | `--waitForLst`    | `True`                         | Launch detection: wait for a specific string in the `*.lst`.           |
| `wait_for_tmp`      | `--waitForTmp`    | `False`                        | Launch detection: wait for the `*.tmp` file. (Requires Type3830.)      |
| `detect_timeout_ms` | `--detectTimeout` | `0`                            | Timeout in ms for the detection stages; `0` = unlimited.               |
| `extra_delay_ms`    | `--extraDelay`    | `0`                            | Additional delay in ms after detection passes.                         |
| `poll_ms`           | `--pollMs`        | `100`                          | Polling interval in ms for the output files and the process.           |
| `watch_log`         | `--watchLog`      | `True`                         | Stream `*.log` entries as `LOG` events.                                |
| `watch_tmp`         | `--watchTmp`      | `False`                        | Stream `*.tmp` updates as `CONFIG`/`PROGRESS` events. (Type3830.)      |
| `watch_timeout_ms`  | `--watchTimeout`  | `0`                            | Maximum monitoring duration in ms; `0` = unlimited.                    |
| `stall_timeout_ms`  | `--stallTimeout`  | `0`                            | Max wall-clock ms without progress; `0` = disabled. Needs `watch_tmp`. |
| `clean_on_success`  | `--clean`         | `False`                        | On success, delete `*.tmp`, `*.log`, `*.lst`, and `*.PTI`.             |
| `kill_on_timeout`   | `--killOnTimeout` | `False`                        | Kill TRNSYS on a detection or watch timeout.                           |
| `kill_on_stall`     | `--killOnStall`   | `False`                        | Kill TRNSYS when a stall is detected.                                  |
| `severity`          | `--severity`      | `"Notice"`                     | Minimum log severity to emit: `Notice`, `Warning`, `Fatal`.            |
| `write_events`      | `--writeEvents`   | `False`                        | Write every event to `<deckFile>.jsonl`, replacing any existing file. |

## Display

A live terminal display is enabled by default: one line per simulation, refreshed every
`refresh_interval` seconds. Pass `refresh_interval=0` (or any non-positive value) to disable it.

## Recipes

### Batch run with full monitoring

Python equivalent of the runner's batch recipe: runtime and stall monitoring per run, cleanup on
success, and a summary at the end.

```python
from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(
    watch_tmp=True,
    watch_timeout_ms=300_000,
    kill_on_timeout=True,
    stall_timeout_ms=300_000,
    kill_on_stall=True,
    clean_on_success=True,
)

decks = sorted(Path(r"C:\path\to\dck").glob("*.dck"))

with SimulationManager(max_concurrent=4) as manager:
    for deck in decks:
        manager.add(deck, config)

    manager.wait()

    for sim in manager.failed:
        print(f"{sim.deck_path} failed: exit={sim.exit_code} error={sim.error!r}")
```
