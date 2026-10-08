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

By default, the manager also shows its runs with a
[`ProgressDisplay`](#progressdisplay), which it closes on `shutdown()`. Pass
`display=False` when you show the runs yourself, for example in a GUI.

A background thread updates the handles every `poll_interval` seconds, so they
keep moving whether or not you call `wait()`: a notebook cell can submit runs
and return while the display keeps following them. Each update is one request
for the runs changed since the previous update, with only their new log
entries, so it costs what changed, not the number of runs: a queued deck is
reported once when submitted, then costs nothing while it waits. It then
removes finished runs so the daemon can release them.

Simulation state comes only from daemon replies. Once the daemon reports
`FINISHED`, that state and log history never change. If a request fails, it
raises from the call that sent it, and handles keep their last daemon reply. A
failed background update, such as the daemon exiting, stops the updates and is
kept in `failure`; `wait()` raises it. After `shutdown()`, unfinished handles
keep their last reply too; they are not marked finished.

Once a run has finished, the manager forgets it: the handle you got from
`add()` is the only reference left, so keep the handles you need.

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

  Seconds between background updates of the handles. Must be positive.

- _`display`_ (`bool | Renderer`, default: `True`)

  Show the runs with the built-in [`ProgressDisplay`](#progressdisplay).
  `False` shows nothing; a `Renderer` draws the built-in display on that
  output surface instead of the automatic terminal or notebook one.

- _`refresh_interval`_ (`float`, default: `1.0`)

  Seconds between display redraws. Must be positive.

An explicitly configured manager:

```python
from pathlib import Path

from trnrun import SimulationManager

with SimulationManager(
    max_concurrent=4,
    trnrun_path=Path(r"C:\path\to\trnrun.exe"),
    trnrund_path=Path(r"C:\path\to\trnrund.exe"),
    poll_interval=0.25,
    display=True,
    refresh_interval=0.5,
) as manager:
    ...
```

### Methods and properties

- _`client`_ (`DaemonClient`)

  The client the manager sends its requests through. Use it to ask the daemon
  directly, but never to `add` or `remove` runs the manager tracks.

- _`display`_ (`ProgressDisplay | None`)

  The built-in display showing the runs, or `None` with `display=False`.

- _`active`_ (`list[Simulation]`)

  Copy of the list of unfinished handles in submission order, including runs
  still queued for a worker.

- _`started`_ (`list[Simulation]`)

  Copy of the list of unfinished handles a worker took, `ACCEPTED` or
  `RUNNING`, in the order they started. It never includes queued runs, so it
  stays as small as `max_concurrent` however many runs wait: read it rather
  than filtering `active` to show what is running now.

- _`failure`_ (`Exception | None`)

  The error that stopped background updates, such as the daemon exiting, or
  `None` while they run. A GUI can check it on its timer.

- _`add(deck_file: str | Path, config: SimulationConfig, *, wait_for: SimulationState | None = SimulationState.QUEUED, timeout: float | None = None) -> Simulation`_

  Validate and submit `deck_file` using `config`, and return its handle once
  the run reaches `wait_for` or any later state:

  | `wait_for` | Returns | For example |
  |---|---|---|
  | `None` | at once; the background thread sends the run | submitting a large batch quickly |
  | `QUEUED` (default) | once the daemon has the run | most scripts |
  | `ACCEPTED` | once a worker took it | keeping the queue on your side, deciding what runs next |
  | `RUNNING` | once TRNRun started | timing or logging actual starts |
  | `FINISHED` | once it is done | running decks one after another |

  A run that fails to launch goes from `ACCEPTED` to `FINISHED`, which also
  satisfies `RUNNING`. Runs are sent in the order they are added, whatever
  each one waits for.

  Raises `FileNotFoundError` for a missing deck or TRNSYS executable, and
  `ValueError` for a deck that is not a `.dck` or `.trd` file, before
  submitting anything. Raises `ValueError` with the daemon's message if the
  daemon rejects the run, `TimeoutError` if it has not reached `wait_for`
  within `timeout` seconds, though it stays submitted, and `RuntimeError` once
  the manager is closed or the daemon exited. With `wait_for=None`, nobody
  waits to catch a rejection, so the handle finishes with an `ERROR` status
  and the daemon's message in `error` instead.

- _`update() -> list[Simulation]`_

  Update the tracked handles from the daemon now, without waiting for the
  next background update, then forget finished runs. Runs added with
  `wait_for=None` are sent first. Returns the handles that changed, including
  those that finished or were rejected. Raises `RuntimeError` once the manager
  is closed or the daemon exited.

- _`wait(*simulations: Simulation, timeout: float | None = None) -> None`_

  Block until the given simulations have finished, or with no argument, until
  no run is unfinished. Raises `TimeoutError` if they have not after `timeout`
  seconds, `RuntimeError` once the manager is closed, and the `failure` that
  stopped background updates.

- _`shutdown() -> None`_

  Kill the daemon and its runs, close the display, stop background updates,
  and release tracked runs. Simulation handles retain their last daemon reply
  and logs. Later calls do nothing.

Example manager workflow with every method and property:

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)
manager = SimulationManager(max_concurrent=2)

try:
    first = manager.add(r"C:\path\to\first.dck", config)
    second = manager.add(r"C:\path\to\second.dck", config)
    print(f"Unfinished: {len(manager.active)}")

    print(f"Changed now: {manager.update()}")
    print(f"First state: {first.state}")
    print(f"Daemon revision: {manager.client.changes().revision}")

    manager.wait(first)
    print(f"First status: {first.snapshot().status}")

    manager.wait(timeout=3600)
    print(f"Background failure: {manager.failure}")
    print(f"First succeeded: {first.succeeded}")
    print(f"Second succeeded: {second.succeeded}")

finally:
    manager.shutdown()
```

## `DaemonClient`

`DaemonClient` starts one `trnrund.exe` daemon and sends it requests, one
method per daemon command. It keeps no state: you choose each run ID, and
decide when to poll and remove runs. `SimulationManager` is built on it; use
the client directly when you want that control yourself. Requests from several
threads are serialized.

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

- _`changes(since: int = 0) -> Changes`_

  The daemon's current `revision`, and the `simulations` changed after
  `since` by run ID, in submission order, each with only the log entries that
  arrived after it. Every change to a run, its submission included, gets the
  next revision. Pass the previous `revision` as `since` to poll only what
  changed; each reply's `log_start` says where its logs belong. `since=0`
  returns every simulation with all its logs.

- _`remove(run_id: str) -> None`_

  Forget a finished simulation, so its run ID can be reused. Raises
  `ValueError` for an unfinished one.

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

    revision, logs, unfinished = 0, {"first": 0, "second": 0}, {"first", "second"}
    while unfinished:
        time.sleep(0.5)
        changes = client.changes(revision)
        revision = changes.revision
        for run_id, reply in changes.simulations.items():
            logs[run_id] += len(reply.logs)
            if reply.state is SimulationState.FINISHED:
                print(f"{run_id}: succeeded={reply.succeeded}, logs={logs[run_id]}")
                client.remove(run_id)
                unfinished.discard(run_id)

    client.shutdown()
```

## `Simulation`

`SimulationManager.add()` returns a live `Simulation` for one run. The manager
keeps it current from its background thread; inspect it rather than updating
it yourself.
Individual properties are synchronized, but separate reads may reflect different
moments. Use `snapshot()` when you need a consistent set of display fields.

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
  fetched with each update, and a finished run has all of them.

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

- _`snapshot() -> SimulationSnapshot`_

  Immutable, coherent display view of `id`, `deck_path`, `state`, `status`,
  `progress`, `config_event`, `notices`, `warnings`, and `fatals`, without
  accessing log history. It also provides `is_accepted`, `is_finished`, and
  `is_running`. Outcome details and `log_count` stay on `Simulation`.
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
terminal, or in a Jupyter notebook when running inside a kernel. Every
`SimulationManager` creates one by default, so you only build one yourself for
a manager created with `display=False`. It redraws from its own background
thread, so it never blocks. It only reads the handles, which the manager keeps
current from its own background thread.

Each redraw picks up the manager's `started` runs, those a daemon worker has
accepted, prints every newly finished run once, as a final line, and redraws
the running ones below. Queued runs are never read nor drawn: with 100,000
submissions and four workers, each redraw handles four runs. A run that is accepted and finishes between two redraws is
never seen, so it gets no final line; its handle still holds the result.
Rendering failures are logged to the `trnrun.display` logger and never affect
the runs.

The manager closes its own display on `shutdown()`. Use one you built as a
context manager inside the manager's, or call `close()`, so the last finished
runs are printed before the program exits. Closing prints
only daemon-confirmed finished runs, clears the live rows, and stops following
unfinished runs without changing their state.

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
with SimulationManager(max_concurrent=2, display=False) as manager, ProgressDisplay(manager, refresh_interval=0.5):
    for deck in (r"C:\path\to\first.dck", r"C:\path\to\second.dck"):
        manager.add(deck, config)
    manager.wait()
```

## Building your own display

With `display=False`, `SimulationManager` prints nothing, so a GUI or any other
display just reads the handles, which the manager keeps current. Keep the
handles from `add()`, and from a timer on your UI thread, read each one with
`snapshot()`, which never waits on the daemon. Once a snapshot is finished, it
is final: show the outcome, then drop the handle.

`examples/example_gui.py` is a complete one:

```python
import tkinter as tk

from trnrun import Simulation, SimulationConfig, SimulationManager

root = tk.Tk()
manager = SimulationManager(max_concurrent=2, display=False)  # The window is the display.
labels: dict[Simulation, tk.Label] = {}  # Lines still changing.

for deck in (r"C:\path\to\first.dck", r"C:\path\to\second.dck"):
    label = tk.Label(root, anchor="w", width=60, text=f"{deck}: QUEUED")
    label.pack()
    labels[manager.add(deck, SimulationConfig(watch_tmp=True))] = label


def tick() -> None:
    for simulation, label in list(labels.items()):
        snapshot = simulation.snapshot()
        if not snapshot.is_accepted:
            continue  # Still queued: nothing new to draw.
        percent = f"{snapshot.progress.percent:.0%}" if snapshot.progress else ""
        label["text"] = f"{snapshot.deck_path.name}: {snapshot.status or snapshot.state} {percent}"
        if snapshot.is_finished:
            del labels[simulation]  # Final: drawn once, never again.
    root.after(500, tick)


def close() -> None:
    manager.shutdown()
    root.destroy()


root.protocol("WM_DELETE_WINDOW", close)
tick()
root.mainloop()
```

Never call `wait()` from a UI thread, since it blocks until the runs finish.
If `manager.failure` is set, the daemon exited or stopped answering; handles
keep their last state.

## Migrating from 0.6

Version 0.7 replaces the `trnrunq.exe` queue with the `trnrund.exe` daemon,
and moves the progress display into its own `ProgressDisplay`, which the
manager still shows by default.

- `SimulationConfig.trnrun_path` moved to `SimulationManager(trnrun_path=...)`,
  because one daemon runs every simulation with the same runner.
- `SimulationManager(trnrunq_path=...)` is now `trnrund_path=...`.
- `SimulationManager(refresh_interval=0)` no longer disables the display, and
  raises `ValueError`; pass `display=False` instead. Display callbacks no
  longer exist: read handles with `snapshot()` for your own display.
- `submitted`, `simulations`, `succeeded`, and `failed` were removed, because
  the manager forgets finished runs. Keep the handles returned by `add()`.
- `wait()` accepts several simulations and a `timeout`.
- The manager still keeps handles current in the background, now by polling
  the daemon every `poll_interval` seconds. `update()` polls at once, and
  `failure` holds the error that stopped polling. `DaemonClient` sends daemon
  requests directly.
- On shutdown or a daemon failure, unfinished runs retain their last daemon
  state, and `wait()` raises instead of waiting indefinitely.
- `Simulation.completion_event` and `QueueEvent` were removed. Use
  `Simulation.state`, `exit_code`, and `error` instead.
- Events no longer have a `timestamp`.
- `succeeded` now also requires exit code `0` and no daemon error.
- If the daemon rejects a deck, `add()` raises `ValueError` instead of
  the run finishing as a failure, unless it was added with `wait_for=None`.
- `add(blocking=...)` is now `add(wait_for=...)`: `None` returns at once, and
  `QUEUED`, the default, `ACCEPTED`, `RUNNING`, or `FINISHED` wait for that
  state, up to an optional `timeout`.

## Examples

Runnable examples are available
in the [TRNRun repository](https://github.com/NRCan/TRNRun/tree/main/libraries/python/examples).
