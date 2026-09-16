<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="../../assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="../..assets/trnrun-black.svg">
    <img alt="TRNRun" src="./assets/trnrun-black.svg">
  </picture>
</p>

Thin Python wrapper for running and monitoring
[TRNSYS](https://www.trnsys.com/) batch simulations. The
package includes the `trnrun.exe` runner and `trnrunq.exe` queue.

## Requirements

- Windows x64
- Python 3.12 or newer
- TRNSYS 17 or 18
- Optional: [Type3830 Progress Tracker](../../components/type3830/) for
  progress and stall monitoring

## Installation

Install with pip:

```powershell
pip install trnrun
```

Or with uv:

```powershell
uv add trnrun
```

## Quick start

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig()

with SimulationManager(max_concurrent=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", config)
    manager.wait(simulation)

if simulation.succeeded:
    print(f"Completed: {simulation.deck_path}")
else:
    print(f"Failed: {simulation.deck_path}")
```

## Run a batch

```python
from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=true)
decks = sorted(Path(r"C:\path\to\decks").glob("*.dck"))

with SimulationManager(max_concurrent=4) as manager:
    simulations = [manager.add(deck, config) for deck in decks]
    manager.wait()

print(f"{len(manager.succeeded)} succeeded, {len(manager.failed)} failed")
```

## `SimulationConfig`

`SimulationConfig` defines how one deck is launched and monitored.

### Executables and window

- _`trnrun_path`_ (`str | Path`, default: bundled `trnrun.exe`)

  Path to the `trnrun.exe` executable.

- _`trnexe_path`_ (`str | Path`, default:
  `C:\TRNSYS18\Exe\TrnEXE64.exe`)

  Path to the `TrnEXE64.exe` or `TrnEXE.exe` executable.

- _`gui_visibility`_ (`str`, default: `"hidden"`)

  Controls the TRNSYS simulation window. Values are case-insensitive:

  - `keep` / `keepOpen`: show the window and leave it open after the simulation.
  - `auto` / `autoClose`: show the window and close it after the simulation.
  - `min` / `minimized`: minimize the window and leave it open afterward.
  - `minAuto` / `minimizedAuto`: minimize the window and close it afterward.
  - `hidden`: hide the window and close it after the simulation.

### Launch detection

- _`wait_for_gui`_ (`bool`, default: `True`)

  Wait for a recognized TRNSYS simulation window as part of the launch-readiness checks.

- _`wait_for_lst`_ (`bool`, default: `True`)

  Wait for the component-order header in the deck's `.lst` file.

- _`wait_for_tmp`_ (`bool`, default: `False`)

  Wait for a Type3830 `.tmp` file. Do not enable this for a deck without
  Type3830, or launch detection will wait until its deadline.

- _`detect_timeout_ms`_ (`int`, default: `300_000`)

  Maximum time, in milliseconds, to wait for launch readiness. Set to `0` to
  wait indefinitely. The runner holds the launch mutex for the current Windows
  session until detection completes.

- _`extra_delay_ms`_ (`int`, default: `0`)

  Additional delay in milliseconds after all enabled readiness checks pass.

### Runtime monitoring

- _`poll_ms`_ (`int`, default: `100`)

  Polling interval in milliseconds for the TRNSYS process and output files.
  Values below `1` are clamped to `1`.

- _`watch_log`_ (`bool`, default: `True`)

  Read the deck's `.log` file and emit parsed `LOG` events.

- _`watch_tmp`_ (`bool`, default: `False`)

  Read Type3830 `.tmp` updates and emit configuration and progress events.
  Required for progress-based `CANCELLED` and `STALLED` outcomes.

- _`watch_timeout_ms`_ (`int`, default: `0`)

  Maximum runtime-monitoring duration in milliseconds. `0` means unlimited.

- _`stall_timeout_ms`_ (`int`, default: `0`)

  Maximum milliseconds without simulation-time progress. `0` disables stall
  detection. Requires `watch_tmp=True` and a valid Type3830 snapshot.

- _`kill_on_timeout`_ (`bool`, default: `False`)

  Terminate the owned TRNSYS process when launch detection or runtime
  monitoring times out. If disabled, a detection timeout proceeds to runtime
  monitoring; after a runtime-monitoring timeout, `trnrun.exe` stops polling
  and waits for the process to exit.

- _`kill_on_stall`_ (`bool`, default: `False`)

  Terminate the owned TRNSYS process after detecting a stall. Without it, 
  the `trnrun.exe` waits for process exit.

### Output and cleanup

- _`clean_on_success`_ (`bool`, default: `False`)

  Delete `.tmp`, `.log`, `.lst`, and `.PTI` sidecar files after a successful
  run.

- _`severity`_ (`str`, default: `"Notice"`)

  Minimum emitted log severity: `Notice`, `Warning`, or `Fatal`,
  case-insensitively.

- _`write_events`_ (`bool`, default: `False`)

  Mirror emitted runner events to a `.jsonl` file beside the deck, replacing
  any existing file when the run starts.

A configuration with every parameter set explicitly:

```python
from pathlib import Path

from trnrun import SimulationConfig

config = SimulationConfig(
    trnrun_path=Path(r"C:\path\to\trnrun.exe"),
    trnexe_path=Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe"),
    gui_visibility="hidden",
    wait_for_gui=True,
    wait_for_lst=True,
    wait_for_tmp=True,
    detect_timeout_ms=300_000,
    extra_delay_ms=0,
    poll_ms=100,
    watch_log=True,
    watch_tmp=True,
    watch_timeout_ms=300_000,
    stall_timeout_ms=300_000,
    clean_on_success=True,
    kill_on_timeout=True,
    kill_on_stall=True,
    severity="Notice",
    write_events=False,
)
```

## `SimulationManager`

`SimulationManager` owns one queue process and controls how simulations are
submitted, monitored, and displayed. It is synchronous and intended for use
from one thread. Simulation state advances only while `add()`, `wait()`,
`follow()`, or `shutdown()` reads queue output. 

### Parameters

- _`max_concurrent`_ (`int`, default: logical processor count minus one, at
  least `1`)

  Maximum number of runners that may execute concurrently. Additional
  submissions wait for a worker.

- _`refresh_interval`_ (`float`, default: `1.0`)

  Minimum seconds between terminal-display redraws while events are being read. 
  Set to `0` or a negative value to disable the built-in display.

- _`trnrunq_path`_ (`str | Path`, default: bundled `trnrunq.exe`)

  Path to the `trnrunq.exe` executable.

A manager with every parameter set explicitly:

```python
from pathlib import Path

from trnrun import SimulationManager

with SimulationManager(
    max_concurrent=4,
    refresh_interval=1.0,
    trnrunq_path=Path(r"C:\path\to\trnrunq.exe"),
) as manager:
    ...
```

### Methods and properties

- _`simulations`_ (`list[Simulation]`)

  Snapshot of all queue-accepted simulations in acceptance order.

- _`succeeded`_ (`list[Simulation]`)

  Snapshot of accepted simulations that completed successfully.

- _`failed`_ (`list[Simulation]`)

  Snapshot of simulations that completed without succeeding. Pending and
  running simulations are not included.

- _`add(deck_file: str | Path, config: SimulationConfig) -> Simulation`_

  Validate and submit `deck_file` using a copy of `config`. Blocks until a queue
  worker accepts the request and returns its `Simulation`. If every worker is
  occupied, this may not return until an earlier simulation finishes.

- _`wait(simulation: Simulation | None = None) -> None`_

  With no argument, process events until every accepted simulation completes.
  Pass a manager-owned `Simulation` to return when that run completes while
  continuing to process updates from other runs. There is no client-side
  timeout.

- _`follow(simulation: Simulation | None = None) -> Iterator[Simulation]`_

  With no argument, yield the affected `Simulation` after every newly processed
  event until all runs complete. Pass a manager-owned `Simulation` to yield only
  that run's updates and return when it completes. Events for other runs are
  still processed, and previously consumed events are not replayed.

- _`shutdown() -> None`_

  Close queue input, finish accepted work, and reap the queue process. Called
  automatically when leaving a `with` block.

Example manager workflow with every method and property:

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=true)
manager = SimulationManager(max_concurrent=2)

try:
    first = manager.add(r"C:\path\to\first.dck", config)
    second = manager.add(r"C:\path\to\second.dck", config)

    for updated in manager.follow(first):
        if updated.status is not None:
            print(f"{updated.deck_path}: {updated.status.status}")

    manager.wait()
    print(f"Simulations: {len(manager.simulations)}")
    print(f"Succeeded: {len(manager.succeeded)}")
    print(f"Failed: {len(manager.failed)}")
    print(f"First succeeded: {first.succeeded}")
    print(f"Second succeeded: {second.succeeded}")
finally:
    manager.shutdown()
```

## `Simulation`

`SimulationManager.add()` returns a `Simulation` containing the current state and
results of one run. The manager updates this object as it processes queue events;
applications normally inspect it rather than constructing or updating it
directly.

### Identity and configuration

- _`id`_ (`int`)

  Manager-assigned simulation identifier. The queue uses its string form as the
  run ID.

- _`deck_path`_ (`Path`)

  Absolute path to the submitted deck.

- _`config`_ (`SimulationConfig`)

  Independent copy of the configuration used for this run.

### Events

- _`status`_ (`StatusEvent | None`)

  Latest runner status, or `None` before the first status event. Terminal status
  values are `DONE`, `ERROR`, `CANCELLED`, `TIMEOUT`, and `STALLED`.

- _`progress`_ (`ProgressEvent | None`)

  Latest Type3830 progress event, or `None` when progress has not been reported.
  `percent` is a fraction from `0` to `1`; `elapsed` and `eta` are milliseconds.

- _`config_event`_ (`ConfigEvent | None`)

  Latest simulation-time configuration event, containing `start`, `stop`, and
  `step`, or `None` before Type3830 reports it.

- _`setting_event`_ (`SettingEvent | None`)

  `trnrun.exe` settings reported when the simulation starts, or `None` before they
  are received.

- _`completion_event`_ (`QueueEvent | None`)

  Queue completion metadata, including `exit_code`, or `None` until the queue
  finishes the request. `exit_code` is `None` if the runner could not be launched.

- _`logs`_ (`list[LogEvent]`)

  Snapshot of the latest 5,000 log events in arrival order. Older events are
  discarded from this list, but remain included in the log counters.

### State and outcome

- _`is_running`_ (`bool`)

  Whether the simulation is pending or running and has not received queue
  completion.

- _`is_accepted`_ (`bool`)

  Whether a queue worker has accepted the request.

- _`is_finished`_ (`bool`)

  Whether the queue has reported completion for the request.

- _`has_terminal_status`_ (`bool`)

  Whether the runner has reported one of the canonical terminal statuses.

- _`succeeded`_ (`bool`)

  Whether the queue completed the request and the latest runner status is
  exactly `DONE`.

### Log counters

- _`log_count`_ (`int`)

  Total number of received log events.

- _`notices`_ (`int`)

  Number of received `Notice` log events.

- _`warnings`_ (`int`)

  Number of received `Warning` log events.

- _`fatals`_ (`int`)

  Number of received `Fatal` log events.

An example inspecting every property:

```python
from trnrun import SimulationConfig, SimulationManager

with SimulationManager(max_concurrent=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", SimulationConfig(watch_tmp=true))
    manager.wait(simulation)

print(f"ID: {simulation.id}")
print(f"Deck: {simulation.deck_path}")
print(f"Config: {simulation.config}")
print(f"Running: {simulation.is_running}")
print(f"Accepted: {simulation.is_accepted}")
print(f"Finished: {simulation.is_finished}")
print(f"Terminal status received: {simulation.has_terminal_status}")
print(f"Succeeded: {simulation.succeeded}")
print(f"Status: {simulation.status}")
print(f"Progress: {simulation.progress}")
print(f"Simulation config event: {simulation.config_event}")
print(f"Runner settings: {simulation.setting_event}")
print(f"Queue completion: {simulation.completion_event}")
print(f"Logs: {simulation.logs}")
print(f"Log count: {simulation.log_count}")
print(f"Notices: {simulation.notices}")
print(f"Warnings: {simulation.warnings}")
print(f"Fatals: {simulation.fatals}")
```

Runnable examples are available
in the [TRNRun repository](https://github.com/NRCan/TRNRun/tree/main/libraries/python/examples).
