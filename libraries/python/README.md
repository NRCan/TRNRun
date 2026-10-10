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
- [Core and convenience](#core-and-convenience)
- [Quick start](#quick-start)
- [Run a batch](#run-a-batch)
- [`SimulationConfig`](#simulationconfig)
- [`SimulationManager`](#simulationmanager)
- [`DaemonClient`](#daemonclient)
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

For the built-in Rich progress display used by the quick start and batch
examples, install the optional `display` extra:

```powershell
pip install "trnrun[display]"
```

Or with uv:

```powershell
uv add "trnrun[display]"
```

For direct client or non-display manager usage, Rich is not required:

```powershell
pip install trnrun
```

The equivalent uv command is `uv add trnrun`. The manager still defaults to
`display=True`, which uses Rich and requires the `display` extra. Pass
`display=False` to use it without Rich.

## Core and convenience

- **Core (`trnrun`)** exports only `DaemonClient`, `SimulationConfig`,
  `SimulationReply`, `SimulationState`, and `SimulationStatus`. It handles
  direct daemon requests and their configuration/replies, without importing
  convenience code or Rich. You choose run IDs, poll for replies, and keep any
  logs you need.
- **Convenience (`trnrun.convenience`)** exports `Display`, `ProgressDisplay`,
  `Simulation`, and `SimulationManager`. It adds background polling, live
  simulation handles, and optional display. The manager remains usable without
  Rich when `display=False`; custom displays need only their own dependencies.

A direct client run with no display:

```python
import time

from trnrun import DaemonClient, SimulationConfig, SimulationState

with DaemonClient(max_concurrent=1) as client:
    client.add("run", r"C:\path\to\deck.dck", SimulationConfig().to_cli_args())
    while True:
        time.sleep(0.25)
        reply = client.pull("run").get("run")
        if reply is not None and reply.state is SimulationState.FINISHED:
            print(f"Succeeded: {reply.succeeded}")
            break
    client.shutdown()
```

For the same run with background polling and a live handle, but no display:

```python
from trnrun import SimulationConfig
from trnrun.convenience import SimulationManager

with SimulationManager(max_concurrent=1, display=False) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", SimulationConfig())
    simulation.wait()
    print(f"Succeeded: {simulation.succeeded}")
```

## Quick start

```python
from trnrun import SimulationConfig
from trnrun.convenience import SimulationManager

config = SimulationConfig()

with SimulationManager(max_concurrent=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", config)
    simulation.wait()

if simulation.succeeded:
    print(f"Completed: {simulation.deck_path}")
else:
    print(f"Failed: {simulation.deck_path}")
```

## Run a batch

```python
from pathlib import Path

from trnrun import SimulationConfig
from trnrun.convenience import SimulationManager

config = SimulationConfig(watch_tmp=True)
decks = sorted(Path(r"C:\path\to\decks").glob("*.dck"))

with SimulationManager(max_concurrent=4) as manager:
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

`SimulationManager` owns one `trnrund.exe` daemon, through a
[`DaemonClient`](#daemonclient). Its job is to submit runs and keep their
`Simulation` handles current. The daemon runs the simulations and keeps their
state.

A background thread polls the daemon every `poll_interval` seconds, so the
handles keep moving whether or not you call `wait()`: a notebook cell can
submit runs and return while the display keeps following them. Each poll is
one `pull` of the runs changed since the previous poll, with only their new
log entries, so it costs what changed, not the number of runs. The thread
applies them to the handles, stops tracking finished runs, as the daemon does
once they are pulled, updates the display, then settles the finished handles,
releasing `wait()`. It is the only thread that changes a handle, so reading one
never waits.

By default the manager shows its runs with a
[`ProgressDisplay`](#progressdisplay), which requires `pip install "trnrun[display]"`
and is closed on `shutdown()`. Pass `display=False` for no display or when you
show the runs yourself, for example in a GUI; this does not require Rich. See
[Building your own display](#building-your-own-display).

Simulation state comes only from daemon replies. Once the daemon reports
`FINISHED`, that state and log history never change. A failed poll, such as
the daemon exiting, stops the background thread and is kept in `failure`;
`add()` and `wait()` then raise it. When syncing stops, by a failure or by
`shutdown()`, every unfinished handle is settled with that error, so its
`wait()` raises it instead of hanging. It keeps its last reply; it is not
marked finished.

Once a run has finished, the manager stops tracking it: it leaves `active`, and
the handle you got from `add()` is the only reference left, so keep the handles
you need.

### Parameters

- _`max_concurrent`_ (`int`, default: logical processor count minus one, at
  least `1`)

  Maximum number of runners that may execute concurrently. Additional
  submissions wait in the daemon's queue for a worker.

- _`trnrun_path`_ (`str | Path`, default: bundled `trnrun.exe`)

  Path to the `trnrun.exe` runner used for every simulation of this manager.

- _`trnrund_path`_ (`str | Path`, default: bundled `trnrund.exe`)

  Path to the `trnrund.exe` daemon.

- _`poll_interval`_ (`float`, default: `0.25`)

  Seconds between polls of the daemon, and so between display updates. Must
  be positive.

- _`display`_ (`bool | Display`, default: `True`)

  `True` shows the runs with a new [`ProgressDisplay`](#progressdisplay) and
  requires the `display` extra; `False` shows nothing and works without Rich.
  Any other object with `update(changed)` and `close()`
  methods, such as a `ProgressDisplay` drawing on your own Rich console, is
  updated instead.

An explicitly configured manager:

```python
from pathlib import Path

from trnrun.convenience import SimulationManager

with SimulationManager(
    max_concurrent=4,
    trnrun_path=Path(r"C:\path\to\trnrun.exe"),
    trnrund_path=Path(r"C:\path\to\trnrund.exe"),
    poll_interval=0.25,
    display=True,
) as manager:
    ...
```

### Methods and properties

- _`display`_ (`Display | None`)

  The display the background thread updates, or `None` with `display=False`.

- _`active`_ (`list[Simulation]`)

  Copy of the list of unfinished handles in submission order, including runs
  still queued for a worker.

- _`failure`_ (`Exception | None`)

  The error that stopped background updates, such as the daemon exiting, or
  `None` while they run. A GUI can check it on its timer.

- _`add(deck_file: str | Path, config: SimulationConfig) -> Simulation`_

  Submit `deck_file` to the daemon's queue using `config`, then return its
  handle. The run starts once a worker is free. Raises `FileNotFoundError` for
  a missing TRNSYS executable, before submitting anything. Raises `ValueError`
  with the daemon's message if the daemon rejects the run, such as for a
  missing deck or one that is not a `.dck` or `.trd` file, and `RuntimeError`
  once the manager is closed, the daemon exited, or with the `failure` that
  stopped background updates.

- _`wait(timeout: float | None = None) -> None`_

  Block until every run has finished, including runs added meanwhile. To wait
  for one run, use [`Simulation.wait()`](#simulation). Raises `TimeoutError`
  if runs are unfinished after `timeout` seconds, `RuntimeError` once the
  manager is closed, and the `failure` that stopped background updates.

- _`shutdown() -> None`_

  Kill the daemon and its runs, stop background updates, settle unfinished
  handles, so their `wait()` raises that the manager is closed, and close the
  display. Simulation handles retain their last daemon reply and logs. Later
  calls do nothing.

Example manager workflow with every method and property:

```python
from trnrun import SimulationConfig
from trnrun.convenience import SimulationManager

config = SimulationConfig(watch_tmp=True)
manager = SimulationManager(max_concurrent=2)

try:
    first = manager.add(r"C:\path\to\first.dck", config)
    second = manager.add(r"C:\path\to\second.dck", config)
    print(f"Unfinished: {len(manager.active)}")
    print(f"Display: {manager.display}")

    first.wait()
    print(f"First status: {first.status}")

    manager.wait(timeout=3600)
    print(f"Background failure: {manager.failure}")
    print(f"First succeeded: {first.succeeded}")
    print(f"Second succeeded: {second.succeeded}")

finally:
    manager.shutdown()
```

## `DaemonClient`

`DaemonClient` starts one `trnrund.exe` daemon and sends it requests, one
method per daemon command. It keeps no state: you choose each run ID and
decide when to poll. `SimulationManager` is built on it; use the client
directly when you want that control yourself. Requests from several threads
are serialized.

A request the daemon rejects, or a malformed reply, raises `ValueError` with
the daemon's message; a daemon that exited raises `RuntimeError`.

### Parameters

The same as [`SimulationManager`](#simulationmanager): `max_concurrent`,
`trnrun_path`, and `trnrund_path`.

### Methods

- _`add(run_id: str, deck_file: str | Path, trnrun_args: Sequence[str] = ()) -> None`_

  Queue a simulation, which starts once a worker is free. `trnrun_args` are
  `trnrun.exe` flags, such as `SimulationConfig.to_cli_args()`. Raises
  `ValueError` if `run_id` is empty or in use, or the deck is missing or not a
  `.dck` or `.trd` file.

- _`pull(run_id: str | None = None) -> dict[str, SimulationReply]`_

  The simulations changed since they were last pulled, their submission
  included, by run ID, in submission order. Each carries only the log entries
  not pulled before, so keep what you receive: each change is pulled once. A
  finished simulation is pulled with its final entries, then forgotten,
  freeing its run ID. With `run_id`, only that simulation is pulled, leaving
  the others for a later pull: the result holds it, or nothing if it has not
  changed. Raises `ValueError` for an unknown or already forgotten `run_id`.

- _`shutdown(timeout: float | None = None) -> None`_

  Have the daemon finish queued runs as cancelled without starting them, wait
  for running ones, and exit. Waits for the exit, up to `timeout` seconds if
  given; on `subprocess.TimeoutExpired`, `kill()` still stops it.

- _`kill() -> None`_

  Kill the daemon and the simulations it runs. Leaving a `with` block calls it.

A run is done when its `state` is `SimulationState.FINISHED`, which includes
failed runs; `succeeded` tells them apart. Its finished reply carries its
final log entries.

```python
import time

from trnrun import DaemonClient, SimulationConfig, SimulationState

args = SimulationConfig(watch_tmp=True).to_cli_args()

with DaemonClient(max_concurrent=2) as client:
    client.add("first", r"C:\path\to\first.dck", args)
    client.add("second", r"C:\path\to\second.dck", args)

    logs, unfinished = {"first": 0, "second": 0}, {"first", "second"}
    while unfinished:
        time.sleep(0.5)
        for run_id, reply in client.pull().items():
            logs[run_id] += len(reply.logs)
            if reply.state is SimulationState.FINISHED:
                print(f"{run_id}: succeeded={reply.succeeded}, logs={logs[run_id]}")
                unfinished.discard(run_id)

    client.shutdown()
```

## `Simulation`

`SimulationManager.add()` returns a live `Simulation` for one run. The
manager's background thread keeps it current; inspect it rather than updating
it yourself.

Each daemon reply replaces the handle's `info` as a whole, so every property is
safe to read from any thread, but separate reads may reflect different
replies. Read `info` once when several fields must agree, as a display does.

### Methods and properties

The submission comes first, then the daemon state in the order trnrund keeps
it, then conveniences derived from it.

- _`id`_ (`int`)

  Manager-assigned simulation identifier. The daemon uses its string form as the
  run ID.

- _`deck_path`_ (`Path`)

  Absolute path to the submitted deck.

- _`config`_ (`SimulationConfig`)

  Independent copy of the configuration used for this run.

- _`info`_ (`SimulationReply`)

  The daemon's latest reply, frozen: `state`, `exit_code`, `error`, `setting`,
  `status`, `config`, `progress`, `notices`, `warnings`, `fatals`, and
  `succeeded`, all from the same moment. Its `logs` is empty; the history is in
  `logs` below. A later reply replaces it rather than changing it, so a
  finished run's `info` is final.

- _`state`_ (`SimulationState`)

  Daemon lifecycle: `QUEUED`, `ACCEPTED`, `RUNNING`, then `FINISHED` once the
  runner has exited or failed to launch, or the daemon shut down before
  starting it.

- _`exit_code`_ (`int | None`)

  Runner exit code, or `None` until it exits or if it could not be launched.

- _`error`_ (`str`)

  Execution error reported by the daemon, such as a launch failure; otherwise
  `""`.

- _`setting_event`_ (`SettingEvent | None`)

  `trnrun.exe` settings reported when the simulation starts, or `None` before they
  are received.

- _`status`_ (`SimulationStatus | None`)

  Latest runner status, or `None` before the first status event. A finished run
  always has one, because the daemon reports `ERROR` if the runner exited
  without a terminal status.

- _`status_event`_ (`StatusEvent | None`)

  Latest status event, including its optional `message`, or `None` before the
  first status event.

- _`config_event`_ (`ConfigEvent | None`)

  Latest simulation-time configuration event, containing `start`, `stop`, and
  `step`, or `None` before Type3830 reports it.

- _`progress`_ (`ProgressEvent | None`)

  Latest Type3830 progress event, or `None` when progress has not been reported.
  `percent` is a fraction from `0` to `1`; `elapsed_ms` and `eta_ms` are milliseconds.

- _`logs`_ (`list[LogEvent]`)

  Copy of all log events in arrival order. The complete history stays in memory
  for the lifetime of the simulation object; no events are evicted. New logs are
  fetched with each poll, and a finished run has all of them.

- _`notices`_ (`int`)

  Number of received `Notice` log events.

- _`warnings`_ (`int`)

  Number of received `Warning` log events.

- _`fatals`_ (`int`)

  Number of received `Fatal` log events.

- _`succeeded`_ (`bool`)

  Whether the run finished with status `SimulationStatus.DONE`, exit code `0`,
  and no daemon error.

- _`log_count`_ (`int`)

  Total number of received log events.

- _`is_accepted`_ (`bool`)

  Whether a daemon worker has accepted the run, meaning `state` is past `QUEUED`.

- _`is_running`_ (`bool`)

  Whether `state` is `RUNNING`.

- _`is_finished`_ (`bool`)

  Whether `state` is `FINISHED`.

- _`wait(timeout: float | None = None) -> None`_

  Block until the run finishes; it may be called from any thread. Raises
  `TimeoutError` if it has not finished after `timeout` seconds, and the error
  that stopped its manager syncing it first, such as `RuntimeError` after
  `shutdown()` or when the daemon exited.

An example inspecting every property:

```python
from trnrun import SimulationConfig
from trnrun.convenience import SimulationManager

with SimulationManager(max_concurrent=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", SimulationConfig(watch_tmp=True))
    simulation.wait()

print(f"ID: {simulation.id}")
print(f"Deck: {simulation.deck_path}")
print(f"Config: {simulation.config}")
print(f"Info: {simulation.info}")
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
```

## `ProgressDisplay`

`ProgressDisplay`, imported from `trnrun.convenience`, requires the optional
Rich dependency installed with `pip install "trnrun[display]"`. It shows live
progress of a manager's runs in a terminal, or in a Jupyter notebook when
running inside a kernel. Every `SimulationManager` creates one by default
(`display=True`). It has no thread of its own: the manager's background
thread calls its `update()` after every poll that changed a run, and its
`close()` on `shutdown()`.

Each update prints every run that finished once, as a final line, and redraws
one live line per unfinished run a worker has taken below them. Queued runs
are never drawn: with 100,000 submissions and four workers, each redraw draws
four lines. A failing display is logged to the `trnrun.convenience.manager` logger and
never affects the runs.

### Parameters

- _`console`_ (`rich.console.Console | None`, default: `None`)

  Rich console to draw on. By default a notebook output inside a Jupyter
  kernel, otherwise the standard terminal.

```python
from rich.console import Console

from trnrun import SimulationConfig
from trnrun.convenience import ProgressDisplay, SimulationManager

config = SimulationConfig(watch_tmp=True)
display = ProgressDisplay(Console(stderr=True))
with SimulationManager(max_concurrent=2, display=display) as manager:
    for deck in (r"C:\path\to\first.dck", r"C:\path\to\second.dck"):
        manager.add(deck, config)
    manager.wait()
```

## Building your own display

With `display=False`, `SimulationManager` prints nothing, so a GUI or any other
display just reads the handles, which the manager keeps current. Keep the
handles from `add()`, and from a timer on your UI thread, read each one's
`info`, which never waits on the daemon. Once a handle is finished, it is
final: show the outcome, then drop it.

`examples/example_gui.py` is a complete one:

```python
import tkinter as tk

from trnrun import SimulationConfig, SimulationState
from trnrun.convenience import Simulation, SimulationManager

root = tk.Tk()
manager = SimulationManager(max_concurrent=2, display=False)  # The window is the display.
labels: dict[Simulation, tk.Label] = {}  # Lines still changing.

for deck in (r"C:\path\to\first.dck", r"C:\path\to\second.dck"):
    label = tk.Label(root, anchor="w", width=60, text=f"{deck}: QUEUED")
    label.pack()
    labels[manager.add(deck, SimulationConfig(watch_tmp=True))] = label


def tick() -> None:
    for simulation, label in list(labels.items()):
        info = simulation.info  # One read, so the fields below agree.
        status = info.status.status if info.status else info.state
        percent = f"{info.progress.percent:.0%}" if info.progress else ""
        label["text"] = f"{simulation.deck_path.name}: {status} {percent}"
        if info.state is SimulationState.FINISHED:
            del labels[simulation]  # Final: drawn once, never again.
    root.after(500, tick)


def close() -> None:
    manager.shutdown()
    root.destroy()


root.protocol("WM_DELETE_WINDOW", close)
tick()
root.mainloop()
```

Reading `active`, `failure`, or a handle never waits on the daemon. `add()`
sends one short request, so it is fine on a UI thread; never call `wait()`
there, since it blocks until the runs finish. If `manager.failure` is set, the
daemon exited or stopped answering; handles keep their last state.

To be told what changed instead of reading on a timer, pass any object with
`update(changed: Sequence[Simulation])` and `close()` methods as `display`. The
manager's background thread calls `update()` with the handles each poll
changed, in submission order, including those that just finished, and `close()`
on `shutdown()`. Since it runs on that thread, a GUI toolkit's widgets must be
updated by handing the work to the UI thread, such as with a Qt signal.

## Migrating from 0.6

Version 0.7 replaces the `trnrunq.exe` queue with the `trnrund.exe` daemon,
and moves the progress display into its own `ProgressDisplay`, which the
manager still shows by default.

- Import `Display`, `ProgressDisplay`, `Simulation`, and `SimulationManager`
  from `trnrun.convenience` instead of `trnrun`. Explicit module imports also
  move: `trnrun.manager`, `trnrun.simulation`, and `trnrun.display` become
  `trnrun.convenience.manager`, `trnrun.convenience.simulation`, and
  `trnrun.convenience.display`. Core config, client, and reply/state/status
  imports remain at `trnrun`.
- Rich is optional: install `pip install "trnrun[display]"` for the built-in
  display (still the manager default), or `pip install trnrun` for client usage
  or a manager with `display=False`.
- `SimulationConfig.trnrun_path` moved to `SimulationManager(trnrun_path=...)`,
  because one daemon runs every simulation with the same runner.
- `SimulationManager(trnrunq_path=...)` is now `trnrund_path=...`.
- `SimulationManager(refresh_interval=...)` was removed: the display is
  updated after each poll, every `poll_interval` seconds. Pass
  `display=False` to disable it. Display callbacks are replaced by any object
  with `update(changed)` and `close()` passed as `display`, or by reading
  handles with `info` for your own display.
- `submitted`, `simulations`, `succeeded`, and `failed` were removed, because
  the manager forgets finished runs. Keep the handles returned by `add()`.
- `manager.wait()` takes a `timeout`; wait for one run with
  `simulation.wait()`.
- The manager still keeps handles current in the background, now by polling
  the daemon every `poll_interval` seconds, and `failure` holds the error that
  stopped polling. `DaemonClient` sends daemon requests directly.
- On shutdown or a daemon failure, unfinished runs retain their last daemon
  state, and both `wait()` methods raise instead of waiting indefinitely.
- `Simulation.completion_event` and `QueueEvent` were removed. Use
  `Simulation.state`, `exit_code`, and `error` instead.
- Events no longer have a `timestamp`.
- `succeeded` now also requires exit code `0` and no daemon error.
- If the daemon rejects a deck, `add()` raises `ValueError` instead of
  the run finishing as a failure.
- `add(blocking=...)` was removed: `add()` returns once the daemon has queued
  the run; use `wait()` to wait for it to finish.

## Examples

Runnable examples are available
in the [TRNRun repository](https://github.com/NRCan/TRNRun/tree/main/libraries/python/examples).
The single-run, batch, and notebook examples use the built-in display and need
`pip install "trnrun[display]"`. The tkinter GUI example uses `display=False`
and works with `pip install trnrun`, without Rich.
