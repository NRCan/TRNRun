# TRNRun - Manager

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
- Python >= 3.11
- TRNSYS v17 or v18
- _Optional: Progress Tracker (Type3830)_ — required for progress events and for stall /
  cancellation detection

## Installation

```sh
pip install trnrun
```

Or from source:

```sh
git clone <repository-url>
cd trnrun-manager
pip install -e .
```

A copy of `trnrun.exe` is bundled with the package under `trnrun/bin/`, so no separate runner
installation is required. A different runner build can be selected via
`SimulationConfig.trnrun_path`.

If TRNSYS is not installed at the default location (`C:\TRNSYS18\Exe\TrnEXE64.exe`), point
`SimulationConfig.trnexe_path` at your `TrnEXE64.exe` / `TrnEXE.exe`.

## Quick start

Run a folder of decks with bounded concurrency:

```python
from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)  # progress events require Type3830

with SimulationManager(max_concurrent=4) as manager:
    for deck in sorted(Path(r"C:\path\to\dck").glob("*.dck")):
        manager.add(deck, config)

    manager.wait()

    print(f"succeeded: {len(manager.succeeded)}  failed: {len(manager.failed)}")
```

`add()` starts each simulation on a worker thread and returns a `Simulation` handle that can be
observed while the run is in flight:

```python
import time

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(refresh_interval=0) as manager:  # 0 disables the built-in display
    sim = manager.add("building.dck", config)

    while not sim.is_finished:
        snap = sim.snapshot()
        if snap.progress is not None:
            print(f"{snap.progress.percent:6.1%}  (W:{snap.warnings} F:{snap.fatals})", end="\r")
        time.sleep(1.0)

    print(f"\nexit code: {sim.exit_code}  succeeded: {sim.succeeded}")
```

## How it works

- Every `add()` spawns one `trnrun.exe` process for the given deck. The runner serializes TRNSYS
  startup across the machine via a global mutex, so concurrent workers cannot interfere with each
  other's launch phase.
- The manager caps concurrency with a bounded worker pool: at most `max_concurrent` runner
  processes exist at any time. When all workers are busy, `add()` blocks until a slot frees,
  providing natural backpressure for large batches.
- Each worker consumes its runner's stdout line by line and folds the parsed events into the
  `Simulation` object, which can be read at any time from any thread.

## Events

The runner emits self-contained JSON objects on stdout, one per line
([JSON Lines](https://jsonlines.org/)). The manager parses them into typed event objects and keeps
the latest of each kind — plus a rolling log window — on the `Simulation`:

```json
{"kind":"STATUS","timestamp":"ISO-8601","status":"PENDING|LAUNCHING|RUNNING|DONE|CANCELLED|ERROR|TIMEOUT|STALLED"}
{"kind":"CONFIG","timestamp":"ISO-8601","start":"hour","stop":"hour","step":"hour"}
{"kind":"PROGRESS","timestamp":"ISO-8601","time":"hour","percent":"0-1","elapsed":"milliseconds","eta":"milliseconds"}
{"kind":"LOG","timestamp":"ISO-8601","severity":"Notice|Warning|Fatal","time":"hour","unitID":"OPTIONAL[INT]","typeID":"OPTIONAL[INT]","messageCode":"OPTIONAL[INT]","message":"OPTIONAL[STRING]","information":"OPTIONAL[STRING]"}
```

| Event      | Mirrored as                                                              |
| ---------- | ------------------------------------------------------------------------ |
| `STATUS`   | `Simulation.status`                                                      |
| `CONFIG`   | `Simulation.config_event` (emitted once, on the first `*.tmp` read)      |
| `PROGRESS` | `Simulation.progress`                                                    |
| `LOG`      | Appended to `Simulation.logs`; counted in `notices`/`warnings`/`fatals`  |

### Simulation states

Reported through `Simulation.status`:

| Status      | Meaning                                                                        |
| ----------- | ------------------------------------------------------------------------------ |
| `PENDING`   | Waiting to acquire the global mutex.                                           |
| `LAUNCHING` | Mutex acquired; TrnEXE is being started.                                       |
| `RUNNING`   | Startup detection passed; the simulation is being monitored.                   |
| `DONE`      | Completed successfully.                                                        |
| `CANCELLED` | The process exited before simulation time reached 100 %.                       |
| `ERROR`     | Failed to launch, died during startup, or logged a fatal error.                |
| `TIMEOUT`   | Exceeded `watch_timeout_ms` (or `detect_timeout_ms` with `kill_on_timeout`).   |
| `STALLED`   | Simulation time stopped advancing for longer than `stall_timeout_ms`.          |

> `CANCELLED` and `STALLED` require `watch_tmp=True` (Type3830), since both are derived from
> simulation progress. Without it, an early exit is reported as `DONE`.

## Exit codes

`Simulation.exit_code` is the runner's exit code:

| Exit code | Meaning                                                                      |
| --------- | ---------------------------------------------------------------------------- |
| `0`       | Simulation completed successfully                                            |
| `1`       | Fatal error during execution                                                 |
| `2`       | Usage or validation error (unknown flag, bad value, missing deck/executable) |
| `124`     | Runtime timeout exceeded (`watch_timeout_ms`)                                |
| `125`     | Simulation stalled (`stall_timeout_ms`)                                      |
| `130`     | Simulation was cancelled                                                     |

plus one manager-side sentinel:

| Exit code | Meaning                                                                                                                                            |
| --------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `-1024`   | The run finished without a usable exit code (e.g. the runner failed to launch, or the run was cancelled before it started). `EXIT_CODE_UNKNOWN`.    |

A simulation counts as **succeeded** only if all of the following hold: exit code `0`, no
Python-side error, no cancellation request, and zero `Fatal` log events.

## API reference

### SimulationManager

Runs simulations using a bounded pool of worker threads.

```python
SimulationManager(max_concurrent=DEFAULT_MAX_CONCURRENT, refresh_interval=1.0)
```

| Parameter          | Type    | Default                        | Description                                                                    |
| ------------------ | ------- | ------------------------------ | ------------------------------------------------------------------------------ |
| `max_concurrent`   | `int`   | `cpu_count() - 1` (at least 1) | Maximum number of simulations running at the same time. Must be >= 1.          |
| `refresh_interval` | `float` | `1.0`                          | Seconds between terminal display updates. A value <= 0 disables the display.   |

| Member                                        | Description                                                                                                                                                                                              |
| --------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `add(deck_file, config)`                      | Start a simulation as soon as a worker is available and return its `Simulation`. Blocks while all workers are busy. Raises `FileNotFoundError` if the deck does not exist, `RuntimeError` after shutdown. |
| `wait(timeout=None)`                          | Block until every simulation added *before this call* has finished, or the timeout (seconds) expires. Returns `True` if all of them finished.                                                             |
| `simulations`                                 | All added simulations, in creation order.                                                                                                                                                                 |
| `succeeded`                                   | Simulations that completed successfully.                                                                                                                                                                  |
| `failed`                                      | Simulations that finished without succeeding (fatal errors, non-zero exit, cancellation, launch failure).                                                                                                 |
| `cancel()`                                    | Request cancellation of every added simulation.                                                                                                                                                           |
| `shutdown(cancel_running=False, wait=True)`   | Close the manager; further `add()` calls raise. With `cancel_running=True` running simulations are cancelled first; with `wait=True` the call blocks until the workers exit.                              |

`SimulationManager` is a context manager. Leaving the `with` block calls `shutdown()`, which waits
for running simulations to finish — it does **not** cancel them. Call `cancel()` or
`shutdown(cancel_running=True)` for that.

### Simulation

A handle for one runner process, normally obtained from `SimulationManager.add()`. TRNRun owns the
simulation state; this object only mirrors the latest events received on stdout, plus local process
bookkeeping (PID, exit code, cancellation).

All members are thread-safe. Each property acquires the internal lock separately, so two
consecutive reads may straddle an event — use `snapshot()` whenever a consistent multi-field view
is required.

| Member                                  | Type                       | Description                                                                                   |
| --------------------------------------- | -------------------------- | --------------------------------------------------------------------------------------------- |
| `id`                                    | `int`                      | Identifier assigned by the manager.                                                           |
| `deck_path`                             | `str`                      | Deck (`.dck`) file passed to the runner.                                                      |
| `status`                                | `StatusEvent \| None`      | Latest `STATUS` event.                                                                        |
| `progress`                              | `ProgressEvent \| None`    | Latest `PROGRESS` event. Requires `watch_tmp=True`.                                           |
| `config_event`                          | `ConfigEvent \| None`      | `CONFIG` event with simulation start / stop / step.                                           |
| `logs`                                  | `list[LogEvent]`           | Rolling window of `LOG` events (default: last 5 000).                                         |
| `log_count`, `notices`, `warnings`, `fatals` | `int`                 | Event counters, kept over the whole run — even after older events leave the rolling window.   |
| `exit_code`                             | `int \| None`              | `None` while running; the runner exit code afterwards (see [Exit codes](#exit-codes)).        |
| `error`                                 | `str \| None`              | Python-side failure description (spawn failure, cancelled before start, ...).                 |
| `cancelled`                             | `bool`                     | Whether `cancel()` was requested.                                                             |
| `pid`                                   | `int \| None`              | Runner process ID.                                                                            |
| `is_running`                            | `bool`                     | Runner process is alive.                                                                      |
| `is_finished`                           | `bool`                     | An exit code has been recorded.                                                               |
| `succeeded`                             | `bool`                     | Success criteria under [Exit codes](#exit-codes).                                             |
| `snapshot()`                            | `SimulationSnapshot`       | Consistent view of all of the above, captured under a single lock.                            |
| `cancel()`                              | `None`                     | Request termination of the runner process. Safe to call before or after start.                |
| `run()`                                 | `None`                     | Spawn the runner and consume stdout until it exits. Called by the manager's worker thread; raises `RuntimeError` on a second call. |

### SimulationSnapshot

Frozen dataclass returned by `Simulation.snapshot()` with the fields `id`, `deck_path`, `status`,
`progress`, `config_event`, `notices`, `warnings`, `fatals`, `log_count`, `exit_code`, `error`,
and `cancelled`. Every field is captured in one critical section, so a consumer can never mix
state from either side of an event.

### SimulationConfig

Dataclass describing how the runner is invoked. Each field maps to a `trnrun.exe` flag (passed as
`--name:value`), and the defaults mirror the runner's own CLI defaults. See the runner
documentation for full flag semantics.

| Field              | Runner flag       | Default                          | Description                                                            |
| ------------------ | ----------------- | -------------------------------- | ---------------------------------------------------------------------- |
| `trnrun_path`      | —                 | bundled `trnrun.exe`             | Runner executable to invoke.                                           |
| `trnexe_path`      | `--trnexePath`    | `C:\TRNSYS18\Exe\TrnEXE64.exe`   | TRNSYS executable (`TrnEXE64.exe` / `TrnEXE.exe`).                     |
| `gui_visibility`   | `--guiVisibility` | `"hidden"`                       | TRNSYS window behavior: `keep`, `auto`, `min`, `minAuto`, `hidden`.    |
| `wait_for_gui`     | `--waitForGui`    | `True`                           | Launch detection: wait for a TRNSYS GUI.                               |
| `wait_for_lst`     | `--waitForLst`    | `True`                           | Launch detection: wait for a specific string in the `*.lst`.           |
| `wait_for_tmp`     | `--waitForTmp`    | `False`                          | Launch detection: wait for the `*.tmp` file. (Requires Type3830.)      |
| `detect_timeout_ms`| `--detectTimeout` | `0`                              | Timeout in ms for the detection stages; `0` = unlimited.               |
| `extra_delay_ms`   | `--extraDelay`    | `0`                              | Additional delay in ms after detection passes.                         |
| `poll_ms`          | `--pollMs`        | `100`                            | Polling interval in ms for the output files and the process.           |
| `watch_log`        | `--watchLog`      | `True`                           | Stream `*.log` entries as `LOG` events.                                |
| `watch_tmp`        | `--watchTmp`      | `False`                          | Stream `*.tmp` updates as `CONFIG`/`PROGRESS` events. (Type3830.)      |
| `watch_timeout_ms` | `--watchTimeout`  | `0`                              | Maximum monitoring duration in ms; `0` = unlimited.                    |
| `stall_timeout_ms` | `--stallTimeout`  | `0`                              | Max wall-clock ms without progress; `0` = disabled. Needs `watch_tmp`. |
| `clean_on_success` | `--clean`         | `False`                          | On success, delete `*.tmp`, `*.log`, `*.lst`, and `*.PTI`.             |
| `kill_on_timeout`  | `--killOnTimeout` | `False`                          | Kill TRNSYS on a detection or watch timeout.                           |
| `kill_on_stall`    | `--killOnStall`   | `False`                          | Kill TRNSYS when a stall is detected.                                  |
| `severity`         | `--severity`      | `"Notice"`                       | Minimum log severity to emit: `Notice`, `Warning`, `Fatal`.            |
| `write_log`        | `--writeLog`      | `False`                          | Also append every event to `<deckFile>.jsonl`.                         |

Two helpers are provided: `validate()` raises `FileNotFoundError` if either executable is missing,
and `to_cli_args()` renders the configuration as `--name:value` arguments.

## Display

A live terminal display is enabled by default: one line per simulation, refreshed every
`refresh_interval` seconds. Pass `refresh_interval=0` (or any non-positive value) to disable it —
for example when running headless, logging to a file, or printing your own progress. Display
failures are logged and never affect the simulations themselves.

## Thread safety

- `SimulationManager` is thread-safe; `add()` may be called from multiple threads.
- All `Simulation` state is guarded by an internal lock and safe to read from any thread while the
  run is in flight. Use `snapshot()` for a consistent multi-field view.
- Machine-wide TRNSYS launch serialization is handled by the runner's global mutex, not by this
  package, so simulations started by other `trnrun` invocations on the same machine coordinate
  automatically.

## Recipes

### Batch run with full monitoring

Python equivalent of the runner's batch recipe: runtime and stall monitoring per run, cleanup on
success, and a summary at the end.

```python
from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(
    watch_tmp=True,              # requires Type3830
    watch_timeout_ms=7_200_000,  # 2 h runtime limit
    kill_on_timeout=True,
    stall_timeout_ms=300_000,    # 5 min without progress
    kill_on_stall=True,
    clean_on_success=True,
)

decks = sorted(Path(r"C:\path\to\dck").glob("*.dck"))

with SimulationManager(max_concurrent=4) as manager:
    for deck in decks:
        manager.add(deck, config)  # blocks while all workers are busy

    manager.wait()

    for sim in manager.failed:
        print(f"{sim.deck_path} failed: exit={sim.exit_code} error={sim.error!r}")
```

### Inspecting failures

```python
for sim in manager.failed:
    snap = sim.snapshot()
    print(f"[{snap.id}] {snap.deck_path}: exit={snap.exit_code}, "
          f"{snap.warnings} warnings, {snap.fatals} fatals")
    for event in sim.logs:
        if event.severity == "Fatal":
            print("   ", event)
```

### Global timeout with cancellation

```python
with SimulationManager(max_concurrent=4) as manager:
    for deck in decks:
        manager.add(deck, config)

    if not manager.wait(timeout=4 * 3600):
        manager.cancel()  # ask the runners to terminate what is left
        manager.wait()    # collect the cancelled results
```

### Streaming decks from a generator

`add()` blocks while all workers are busy, so arbitrarily large batches can be fed without building
them up front:

```python
def parametric_decks():
    for i, params in enumerate(cases):
        yield write_deck(f"case_{i}.dck", params)  # your own deck writer

with SimulationManager(max_concurrent=6, refresh_interval=2.0) as manager:
    for deck in parametric_decks():
        manager.add(deck, config)
    manager.wait()
```

## License

MIT License — see LICENSE file for details.
