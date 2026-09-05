<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
    <img alt="TRNRun" src="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
  </picture>
</p>

Thin Python wrapper for running and monitoring
[TRNSYS](https://www.trnsys.com/) batch simulations. The
package includes the `trnrun.exe` runner and `trnrund.exe` daemon.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Run a batch](#run-a-batch)
- [`SimulationConfig`](#simulationconfig)
- [`SimulationManager`](#simulationmanager)
- [`Simulation`](#simulation)
- [`ProgressDisplay`](#progressdisplay)
- [Building your own display](#building-your-own-display)
- [Migrating from 0.6](#migrating-from-06)
- [Examples](#examples)

## Requirements

- Windows x64
- Python 3.12 or newer
- TRNSYS 17 or 18
- Optional: [Type3830 Progress Tracker](https://github.com/NRCan/TRNRun/tree/main/components/type3830) for
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
from trnrun import ProgressDisplay, SimulationConfig, SimulationManager

config = SimulationConfig()

with SimulationManager(max_concurrent=1) as manager:
    ProgressDisplay(manager)
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

from trnrun import ProgressDisplay, SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)
decks = sorted(Path(r"C:\path\to\decks").glob("*.dck"))

with SimulationManager(max_concurrent=4) as manager:
    ProgressDisplay(manager)
    simulations = [manager.add(deck, config) for deck in decks]
    manager.wait()

succeeded = [simulation for simulation in simulations if simulation.succeeded]
print(f"{len(succeeded)} succeeded, {len(simulations) - len(succeeded)} failed")
```

## `SimulationConfig`

`SimulationConfig` defines how one deck is launched and monitored. The
`trnrun.exe` runner itself is chosen per [`SimulationManager`](#simulationmanager).

### TRNSYS executable and window

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
  Required for progress-based `SimulationStatus.CANCELLED` and
  `SimulationStatus.STALLED` outcomes.

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
  `trnrun.exe` waits for the process to exit.

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

`SimulationManager` owns one `trnrund.exe` daemon process and a background
poller. Its only job is to submit runs and keep their `Simulation` handles
current; it never prints anything. The daemon runs the simulations and keeps
their state. The poller asks it about unfinished runs every `poll_interval`
seconds and right after each submission, fetches only new log entries, and
collects finished runs so the daemon can release them.

Every `Simulation` returned by `add()` reaches `FINISHED` exactly once, and
never changes afterwards:

- normally, with the daemon's verdict;
- with status `ERROR` if the daemon fails, the failure in `manager.error`;
- with status `CANCELLED` if the manager shuts down first.

Once a run has finished, the manager forgets it: the handle you got from
`add()` is the only reference left, so keep the handles you need.

### Parameters

- _`max_concurrent`_ (`int`, default: logical processor count minus one, at
  least `1`)

  Maximum number of runners that may execute concurrently. Additional
  submissions wait in the daemon's queue for a worker.

- _`poll_interval`_ (`float`, default: `0.25`)

  Seconds between daemon polls. Must be positive.

- _`trnrun_path`_ (`str | Path`, default: bundled `trnrun.exe`)

  Path to the `trnrun.exe` runner used for every simulation of this manager.

- _`trnrund_path`_ (`str | Path`, default: bundled `trnrund.exe`)

  Path to the `trnrund.exe` daemon.

An explicitly configured manager:

```python
from pathlib import Path

from trnrun import SimulationManager

with SimulationManager(
    max_concurrent=4,
    poll_interval=0.25,
    trnrun_path=Path(r"C:\path\to\trnrun.exe"),
    trnrund_path=Path(r"C:\path\to\trnrund.exe"),
) as manager:
    ...
```

### Methods and properties

- _`active`_ (`list[Simulation]`)

  Copy of the list of unfinished handles in submission order, including runs
  still queued for a worker.

- _`error`_ (`BaseException | None`)

  The failure that stopped daemon polling, or `None` while polling works.

- _`add(deck_file: str | Path, config: SimulationConfig, *, blocking: bool = True) -> Simulation`_

  Validate and submit `deck_file` using `config`, and return its live handle.
  By default, blocks until a daemon worker accepts the run, so a submission
  loop never queues more runs than the daemon can start. Pass `blocking=False`
  to return a live, initially queued handle as soon as the daemon has it; do
  this from a UI thread. Raises `FileNotFoundError` for a missing deck or
  TRNSYS executable, `ValueError` with the daemon's message if the daemon
  rejects the run, for example a deck that is not a `.dck` or `.trd` file, and
  `RuntimeError` once the manager is closed or polling stopped, including
  while waiting for a worker.

- _`wait(*simulations: Simulation) -> None`_

  Block until the given simulations have finished, or with no argument,
  until no run is unfinished. Raises `RuntimeError` if the manager is closed or
  polling stopped; its cause is `error`.

- _`shutdown() -> None`_

  Stop the daemon. Unfinished simulations finish as `CANCELLED`, then attached
  progress displays print them and close.

Example manager workflow with every method and property:

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)
manager = SimulationManager(max_concurrent=2)

try:
    first = manager.add(r"C:\path\to\first.dck", config)
    second = manager.add(r"C:\path\to\second.dck", config)
    print(f"Unfinished: {len(manager.active)}")

    manager.wait(first)
    print(f"First status: {first.snapshot().status}")

    manager.wait()
    print(f"First succeeded: {first.succeeded}")
    print(f"Second succeeded: {second.succeeded}")
    print(f"Polling error: {manager.error}")

finally:
    manager.shutdown()
```

## `Simulation`

`SimulationManager.add()` returns a live `Simulation` for one run. The manager
updates it from each daemon poll; inspect it rather than updating it yourself.
Individual properties are synchronized, but separate reads may reflect different
moments. Use `snapshot()` when you need a consistent set of fields.

### Methods and properties

- _`id`_ (`int`)

  Manager-assigned simulation identifier. The daemon uses its string form as the
  run ID.

- _`deck_path`_ (`Path`)

  Absolute path to the submitted deck.

- _`config`_ (`SimulationConfig`)

  Independent copy of the configuration used for this run.

- _`state`_ (`SimulationState`)

  Daemon lifecycle: `QUEUED`, `ACCEPTED`, `RUNNING`, then `FINISHED` once the
  runner has exited or failed to launch, or the manager gave up on the run.

- _`status`_ (`SimulationStatus | None`)

  Latest runner status, or `None` before the first status event. A finished run
  always has one, because the daemon reports `ERROR` if the runner exited
  without a terminal status.

- _`status_event`_ (`StatusEvent | None`)

  Latest status event, including its optional `message`, or `None` before the
  first status event.

- _`progress`_ (`ProgressEvent | None`)

  Latest Type3830 progress event, or `None` when progress has not been reported.
  `percent` is a fraction from `0` to `1`; `elapsed_ms` and `eta_ms` are milliseconds.

- _`config_event`_ (`ConfigEvent | None`)

  Latest simulation-time configuration event, containing `start`, `stop`, and
  `step`, or `None` before Type3830 reports it.

- _`setting_event`_ (`SettingEvent | None`)

  `trnrun.exe` settings reported when the simulation starts, or `None` before they
  are received.

- _`exit_code`_ (`int | None`)

  Runner exit code, or `None` until it exits or if it could not be launched.

- _`error`_ (`str`)

  Execution error reported by the daemon, such as a launch failure, or the
  reason the manager finished the run itself; otherwise `""`.

- _`logs`_ (`list[LogEvent]`)

  Copy of all log events in arrival order. The complete history stays in memory
  for the lifetime of the simulation object; no events are evicted. New logs are
  fetched with each poll, and a finished run has all of them.

- _`is_running`_ (`bool`)

  Whether the simulation is queued or running.

- _`is_accepted`_ (`bool`)

  Whether a daemon worker has accepted the run, meaning `state` is past `QUEUED`.

- _`is_finished`_ (`bool`)

  Whether `state` is `FINISHED`.

- _`succeeded`_ (`bool`)

  Whether the run finished with status `SimulationStatus.DONE`, exit code `0`,
  and no daemon error.

- _`log_count`_ (`int`)

  Total number of received log events.

- _`notices`_ (`int`)

  Number of received `Notice` log events.

- _`warnings`_ (`int`)

  Number of received `Warning` log events.

- _`fatals`_ (`int`)

  Number of received `Fatal` log events.

- _`snapshot() -> SimulationSnapshot`_

  Immutable, coherent view of `id`, `deck_path`, `state`, `succeeded`,
  `status`, `message` (the status message), `exit_code`, `error`, `progress`,
  `config_event`, and the log counters, without copying the logs. It also
  provides `is_accepted`, `is_finished`, and `is_running`. `revision` increases
  with every change, so an unchanged revision means nothing needs redrawing.
  The first finished snapshot is the final one.

An example inspecting every property:

```python
from trnrun import SimulationConfig, SimulationManager

with SimulationManager(max_concurrent=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", SimulationConfig(watch_tmp=True))
    manager.wait(simulation)

print(f"ID: {simulation.id}")
print(f"Deck: {simulation.deck_path}")
print(f"Config: {simulation.config}")
print(f"State: {simulation.state}")
print(f"Running: {simulation.is_running}")
print(f"Accepted: {simulation.is_accepted}")
print(f"Finished: {simulation.is_finished}")
print(f"Succeeded: {simulation.succeeded}")
print(f"Status: {simulation.status}")
print(f"Status event: {simulation.status_event}")
print(f"Progress: {simulation.progress}")
print(f"Simulation config event: {simulation.config_event}")
print(f"Runner settings: {simulation.setting_event}")
print(f"Exit code: {simulation.exit_code}")
print(f"Daemon error: {simulation.error}")
print(f"Logs: {simulation.logs}")
print(f"Log count: {simulation.log_count}")
print(f"Notices: {simulation.notices}")
print(f"Warnings: {simulation.warnings}")
print(f"Fatals: {simulation.fatals}")
print(f"Snapshot: {simulation.snapshot()}")
```

## `ProgressDisplay`

`ProgressDisplay(manager)` shows live progress of a manager's runs in a
terminal, or in a Jupyter notebook when running inside a kernel. It redraws
from its own background thread, so it never blocks: submit runs, do other
work, and call `manager.wait()` only if you want to block.

It follows only runs a daemon worker has accepted: those already running when
it is created, and every other run once a worker accepts it. Queued runs are
never followed, so its cost depends on `max_concurrent`, not on how many runs
you submit: with 10,000 submissions and four workers, it draws four lines.
Each redraw prints every newly finished run once, as a final line, and
redraws the running ones below. Rendering failures are logged to the
`trnrun.display` logger and never affect the runs.

The manager closes the display when it shuts down, after cancelling unfinished
runs, so final lines are printed for the runs that had started; runs still
queued are not printed. Call `close()`, or use it as a context manager, to
stop it earlier; runs still unfinished at that point are no longer shown.

### Parameters

- _`manager`_ (`SimulationManager`)

  Open manager whose runs to show.

- _`refresh_interval`_ (`float`, default: `1.0`)

  Seconds between redraws. Must be positive.

- _`renderer`_ (`Renderer | None`, default: `None`)

  Output surface. By default a `NotebookRenderer` inside a Jupyter kernel,
  otherwise a `TerminalRenderer`, both from `trnrun.display`.

```python
from trnrun import ProgressDisplay, SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)
with SimulationManager(max_concurrent=2) as manager:
    ProgressDisplay(manager, refresh_interval=0.5)
    for deck in (r"C:\path\to\first.dck", r"C:\path\to\second.dck"):
        manager.add(deck, config)
    manager.wait()
```

## Building your own display

`SimulationManager` prints nothing on its own, so a GUI or any other display
just reads the handles. Keep the handles from `add()`, and read each one with
`snapshot()` from a timer on your UI thread. A snapshot never waits on the
daemon. Once a snapshot is finished, it is final: show the outcome, then drop
the handle.

```python
import tkinter as tk
from tkinter import ttk

from trnrun import Simulation, SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)
manager = SimulationManager(max_concurrent=2)
root = tk.Tk()
rows: dict[int, tuple[Simulation, ttk.Label, ttk.Progressbar]] = {}


def submit(deck: str) -> None:
    simulation = manager.add(deck, config, blocking=False)  # Returns at once, even while queued.
    label = ttk.Label(root, text=simulation.deck_path.name)
    bar = ttk.Progressbar(root, maximum=1.0, length=300)
    label.pack()
    bar.pack()
    rows[simulation.id] = (simulation, label, bar)


def tick() -> None:
    for sim_id, (simulation, label, bar) in list(rows.items()):
        state = simulation.snapshot()
        if state.progress is not None:
            bar["value"] = state.progress.percent
        label["text"] = f"{state.deck_path.name}: {state.status or 'queued'}"
        if state.is_finished:  # Final, and seen exactly once.
            outcome = "done" if state.succeeded else state.error or state.message or state.status
            label["text"] = f"{state.deck_path.name}: {outcome}"
            del rows[sim_id]
    root.after(500, tick)


def close() -> None:
    manager.shutdown()  # Unfinished runs finish as CANCELLED.
    root.destroy()


for deck in (r"C:\path\to\first.dck", r"C:\path\to\second.dck"):
    submit(deck)
tick()
root.protocol("WM_DELETE_WINDOW", close)
root.mainloop()
```

Guidelines:

- Never call `wait()` from a UI thread; poll snapshots instead.
- Call `add(..., blocking=False)`: it makes one quick request to the daemon,
  and raises at once for a missing or rejected deck. The default blocks until
  a worker is free.
- Skip redrawing a row when its snapshot's `revision` has not changed.
- If the daemon fails, every unfinished run finishes as `ERROR`, so rows
  complete on their own; show `manager.error` once, for example as a banner.
- Call `shutdown()` when the window closes.

## Migrating from 0.6

Version 0.7 replaces the `trnrunq.exe` queue with the `trnrund.exe` daemon,
and separates the progress display from the manager.

- `SimulationConfig.trnrun_path` moved to `SimulationManager(trnrun_path=...)`,
  because one daemon runs every simulation with the same runner.
- `SimulationManager(trnrunq_path=...)` is now `trnrund_path=...`.
- `SimulationManager(refresh_interval=..., display=...)` were removed. Create
  a `ProgressDisplay(manager)` for the built-in display, or read handles with
  `snapshot()` for your own; display callbacks no longer exist.
- `submitted`, `simulations`, `succeeded`, and `failed` were removed, because
  the manager forgets finished runs. Keep the handles returned by `add()`.
- `wait()` accepts several simulations.
- On shutdown, unfinished runs finish as `CANCELLED` instead of keeping their
  last polled state. If the daemon fails, they finish as `ERROR`, and the
  failure is available as `manager.error`.
- `Simulation.completion_event` and `QueueEvent` were removed. Use
  `Simulation.state`, `exit_code`, and `error` instead.
- Events no longer have a `timestamp`.
- `succeeded` now also requires exit code `0` and no daemon error.
- If the daemon rejects a deck, `add()` raises `ValueError` instead of
  the run finishing as a failure.

## Examples

Runnable examples are available
in the [TRNRun repository](https://github.com/NRCan/TRNRun/tree/main/libraries/python/examples).
