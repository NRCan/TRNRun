<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-white.svg">
    <source media="(prefers-color-scheme: light)" srcset="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
    <img alt="TRNRun" src="https://raw.githubusercontent.com/NRCan/TRNRun/main/assets/trnrun-black.svg">
  </picture>
</p>

Thin Python wrapper for running and monitoring
[TRNSYS](https://www.trnsys.com/) batch simulations. The package includes the
`trnrun.exe` runner and the
[`trnrund.exe`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund)
daemon.

## Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Run a batch](#run-a-batch)
- [`SimulationSettings`](#simulationsettings)
- [`SimulationManager`](#simulationmanager)
- [`Simulation`](#simulation)
- [`Daemon`](#daemon)
- [Custom display](#custom-display)
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
from trnrun import SimulationManager

with SimulationManager(workers=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", watch_tmp=True)
    manager.wait(simulation)

if simulation.succeeded:
    print(f"Completed: {simulation.deck_file}")
else:
    print(f"Failed: {simulation.deck_file}")
```

## Run a batch

```python
from pathlib import Path

from trnrun import SimulationManager

decks = sorted(Path(r"C:\path\to\decks").glob("*.dck"))

with SimulationManager(workers=4) as manager:
    for deck in decks:
        manager.add(deck, watch_tmp=True)
    manager.wait()

succeeded = [sim for sim in manager.simulations.values() if sim.succeeded]
print(f"{len(succeeded)} succeeded, {len(decks) - len(succeeded)} failed")
```

## `SimulationSettings`

`SimulationSettings` defines how one deck is launched and monitored. Each field
that is set becomes one
[TRNRun Runner option](https://github.com/NRCan/TRNRun/tree/main/components/trnrun#settings);
a field left at `None` keeps the runner's default, listed below. trnrund checks
the values when the simulation is added.

`add` takes the fields either as a `SimulationSettings` or as keyword
arguments. Keyword arguments override the fields of a `SimulationSettings`
passed with them, and an unknown name raises `TypeError`:

```python
from trnrun import SimulationSettings

settings = SimulationSettings(watch_tmp=True, poll_ms=10)
manager.add(deck, settings)              # watch_tmp=True, poll_ms=10
manager.add(deck, watch_tmp=True)        # the same as SimulationSettings(watch_tmp=True)
manager.add(deck, settings, poll_ms=20)  # watch_tmp=True, poll_ms=20
```

### Executable and window

- _`trnexe_path`_ (`str | Path`, default: `C:\TRNSYS18\Exe\TrnEXE64.exe`)

  Path to the `TrnEXE64.exe` or `TrnEXE.exe` executable. A relative path
  resolves from Python's working directory; a missing file raises
  `FileNotFoundError` before the simulation is queued.

- _`gui_visibility`_ (`str`, default: `"hidden"`)

  Controls the TRNSYS simulation window:

  - `keep`: show the window and leave it open after the simulation.
  - `auto`: show the window and close it after the simulation.
  - `min`: minimize the window and leave it open afterward.
  - `minAuto`: minimize the window and close it afterward.
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

- _`watch_log`_ (`bool`, default: `True`)

  Read the deck's `.log` file and report its entries as `logs`.

- _`watch_tmp`_ (`bool`, default: `False`)

  Read Type3830 `.tmp` updates and report the simulation period and progress.
  Required for progress-based `SimulationStatus.CANCELLED` and
  `SimulationStatus.STALLED` outcomes. Without Type3830 in the deck, an early
  exit is reported as `DONE`.

- _`watch_timeout_ms`_ (`int`, default: `0`)

  Maximum runtime-monitoring duration in milliseconds. `0` means unlimited.

- _`stall_timeout_ms`_ (`int`, default: `0`)

  Maximum milliseconds without simulation-time progress. `0` disables stall
  detection. Requires `watch_tmp=True` and a valid Type3830 snapshot.

- _`kill_on_timeout`_ (`bool`, default: `False`)

  Terminate the TRNSYS process when launch detection or runtime monitoring
  times out. If disabled, a detection timeout proceeds to runtime monitoring;
  after a runtime-monitoring timeout, the runner stops polling and waits for
  the process to exit.

- _`kill_on_stall`_ (`bool`, default: `False`)

  Terminate the TRNSYS process after detecting a stall. Without it, the runner
  waits for the process to exit.

### Output and cleanup

- _`clean_on_success`_ (`bool`, default: `False`)

  Delete `.tmp`, `.log`, `.lst`, and `.PTI` sidecar files after a successful
  run.

- _`severity`_ (`LogSeverity | str`, default: `"Notice"`)

  Minimum reported log severity: `Notice`, `Warning`, or `Fatal`.

- _`write_events`_ (`bool`, default: `False`)

  Mirror the runner events to a `.jsonl` file beside the deck, replacing any
  existing file when the run starts.

A configuration with every field set explicitly:

```python
from pathlib import Path

from trnrun import SimulationSettings

settings = SimulationSettings(
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

`SimulationManager` owns one `trnrund.exe` and keeps a `Simulation` per run up
to date. Nothing runs in the background: simulations are refreshed, and the
display moves, while `add` or `wait` block, or when you call `refresh()`.
Leaving the `with` block, or calling `close()`, kills every unfinished run.

### Parameters

- _`workers`_ (`int`, default: logical processor count minus one, at least `1`)

  Maximum number of simulations running at once. Additional simulations wait
  in the queue.

- _`display`_ (`bool`, default: `True`)

  Show one live line per running simulation and print each finished one once,
  in the terminal or a Jupyter notebook.

- _`poll_interval`_ (`float`, default: `0.1`)

  Seconds between refreshes while `add` or `wait` block.

- _`trnrund_path`_ (`str | Path`, default: bundled `trnrund.exe`)

  Path to the `trnrund.exe` executable.

- _`trnrun_path`_ (`str | Path`, default: bundled `trnrun.exe`)

  Path to the `trnrun.exe` executable.

An explicitly configured manager:

```python
from pathlib import Path

from trnrun import SimulationManager

with SimulationManager(
    workers=4,
    display=True,
    poll_interval=0.1,
    trnrund_path=Path(r"C:\path\to\trnrund.exe"),
    trnrun_path=Path(r"C:\path\to\trnrun.exe"),
) as manager:
    ...
```

### Methods and properties

- _`simulations`_ (`dict[int, Simulation]`)

  Every simulation added, by `sim_id`.

- _`daemon`_ (`Daemon`)

  The [`Daemon`](#daemon) this manager owns, usable directly for other
  commands, such as `manager.daemon.request({...})`.

- _`add(deck_file: str | Path, settings: SimulationSettings | None = None, *, label: str | None = None, wait_for: str | None = None, **options) -> Simulation`_

  Queue `deck_file` and return its `Simulation`. `settings` and `options` are
  the [`SimulationSettings`](#simulationsettings); `label` is free text shown
  instead of the deck path. `wait_for` picks how long `add` blocks:

  | `wait_for`   | `add` returns                                       |
  | ------------ | --------------------------------------------------- |
  | `None`       | at once (default)                                   |
  | `"QUEUED"`   | at once: trnrund has queued it before it answers    |
  | `"RUNNING"`  | once it started, so the next one is added only then |
  | `"FINISHED"` | once it finished: one at a time                     |

- _`wait(*simulations: Simulation, until: str = "FINISHED", timeout: float | None = None) -> None`_

  Block until the given simulations, by default every one added, reach
  `until`. Raises `TimeoutError` after `timeout` seconds.

- _`cancel(*simulations: Simulation) -> None`_

  Stop queued or running simulations; finished ones are left unchanged. The
  next refresh shows them `FINISHED` with status `CANCELLED`.

- _`refresh() -> None`_

  Update every simulation once and redraw the display.

- _`close() -> None`_

  Stop `trnrund.exe`, killing unfinished runs, and erase the live display.

Example manager workflow with every method and property:

```python
from trnrun import SimulationManager

manager = SimulationManager(workers=2)

try:
    first = manager.add(r"C:\path\to\first.dck", watch_tmp=True, wait_for="RUNNING")
    second = manager.add(r"C:\path\to\second.dck", watch_tmp=True, label="second")

    manager.wait(first)
    print(f"First status: {first.status}")

    manager.cancel(second)
    manager.wait(timeout=60)
    manager.refresh()
    print(f"Simulations: {len(manager.simulations)}")
    print(f"First succeeded: {first.succeeded}")
    print(f"Second status: {second.status}")

finally:
    manager.close()
```

## `Simulation`

`SimulationManager.add()` returns a `Simulation` for one run, which the manager
updates in place on each refresh. A field is
`None` until the runner reports it.

### Properties

- _`sim_id`_ (`int`)

  Identifier assigned by the daemon, never reused.

- _`deck_file`_ (`Path`)

  Absolute path to the submitted deck.

- _`label`_ (`str | None`)

  Label it was added with.

- _`trnrun_args`_ (`list[str]`)

  Runner options it was added with, such as `--watchTmp:true`.

- _`state`_ (`SimulationState`)

  `QUEUED` while waiting for a worker, `RUNNING` once the runner started, and
  `FINISHED` once it completed, failed, or was cancelled.

- _`is_finished`_ (`bool`)

  Whether `state` is `FINISHED`; `logs` are then complete.

- _`status`_, _`status_message`_ (`SimulationStatus | None`, `str | None`)

  Latest runner status and its detail.

- _`succeeded`_ (`bool | None`)

  Set once finished. `True` only with status `DONE`, exit code `0`, and no
  `error`.

- _`exit_code`_ (`int | None`)

  Runner exit code; `None` if it was cancelled or never started.

- _`error`_ (`str | None`)

  Why the daemon failed or cancelled the run.

- _`sim_time`_, _`percent`_, _`elapsed_ms`_, _`eta_ms`_ (`float | None`)

  Latest Type3830 progress. `sim_time` is in simulated hours, `percent` is a
  fraction from `0` to `1`, and `elapsed_ms` and `eta_ms` are milliseconds.

- _`start_time`_, _`stop_time`_, _`time_step`_ (`float | None`)

  Simulation period reported by Type3830, in simulated hours.

- _`setting`_ (`dict | None`)

  Settings the runner applied, its defaults included, keyed by the runner's
  camelCase names.

- _`notices`_, _`warnings`_, _`fatals`_ (`int`)

  Number of log entries so far, by severity.

- _`logs`_ (`list[LogEvent]`)

  Log entries, oldest first; filled in once the simulation finishes.

- _`submitted_at`_, _`started_at`_, _`finished_at`_ (`datetime | None`)

  UTC times; `started_at` stays `None` for a simulation that never started.

An example inspecting every property:

```python
from trnrun import SimulationManager

with SimulationManager(workers=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", watch_tmp=True)
    manager.wait(simulation)

print(f"ID: {simulation.sim_id}")
print(f"Deck: {simulation.deck_file}")
print(f"Label: {simulation.label}")
print(f"Runner options: {simulation.trnrun_args}")
print(f"State: {simulation.state}")
print(f"Finished: {simulation.is_finished}")
print(f"Status: {simulation.status} {simulation.status_message}")
print(f"Succeeded: {simulation.succeeded}")
print(f"Exit code: {simulation.exit_code}")
print(f"Error: {simulation.error}")
print(f"Progress: {simulation.percent} at {simulation.sim_time} h")
print(f"Elapsed: {simulation.elapsed_ms} ms, ETA: {simulation.eta_ms} ms")
print(f"Period: {simulation.start_time} to {simulation.stop_time} by {simulation.time_step} h")
print(f"Runner settings: {simulation.setting}")
print(f"Notices: {simulation.notices}")
print(f"Warnings: {simulation.warnings}")
print(f"Fatals: {simulation.fatals}")
print(f"Logs: {simulation.logs}")
print(f"Times: {simulation.submitted_at}, {simulation.started_at}, {simulation.finished_at}")
```

## `Daemon`

`Daemon` is a thin client with one method per
[trnrund command](https://github.com/NRCan/TRNRun/tree/main/components/trnrund#request-protocol),
for applications that do their own polling. Its requests are thread-safe: they
take turns. It takes the `workers`, `trnrund_path`, and `trnrun_path`
parameters of [`SimulationManager`](#parameters).

### Methods

- _`add(deck_file: str | Path, settings: SimulationSettings | None = None, *, label: str | None = None, **options) -> int`_

  Queue `deck_file` and return its `sim_id`, as for `SimulationManager.add`.

- _`simulation(sim_id: int, *, with_logs: bool = False) -> Simulation`_

  Return one simulation, without `logs` unless `with_logs` is `True`.

- _`simulations(state: str, *, with_logs: bool = False) -> list[Simulation]`_

  Return every unreleased simulation in `state`, oldest first.

- _`cancel(sim_id: int) -> None`_

  Stop a queued or running simulation; one already finished is left unchanged.

- _`release(sim_id: int) -> None`_

  Forget a finished simulation and its logs.

- _`request(request: dict) -> dict`_

  Send any raw trnrund request and return its raw response.

- _`close() -> None`_

  Stop `trnrund.exe`, killing unfinished runs.

`RequestError` is raised when trnrund refuses a request, such as for a missing
deck, an unknown `sim_id`, or releasing an unfinished run, and
`DaemonExitedError` when it no longer answers. Both subclass `TrnrunError`.
Simulation outcomes do not raise: inspect each simulation's `succeeded`,
`status`, and `exit_code` instead.

Example daemon workflow with every method:

```python
from time import sleep

from trnrun import Daemon, RequestError

daemon = Daemon(workers=2)

try:
    first = daemon.add(r"C:\path\to\first.dck", watch_tmp=True)
    second = daemon.add(r"C:\path\to\second.dck", watch_tmp=True, label="second")

    print(daemon.simulation(first))
    print(f"Running: {len(daemon.simulations('RUNNING'))}")

    daemon.cancel(second)
    while not daemon.simulation(second).is_finished:
        sleep(0.1)
    cancelled = daemon.simulation(second, with_logs=True)
    print(f"Second status: {cancelled.status}, {len(cancelled.logs)} log entries")
    daemon.release(second)

    try:
        daemon.release(first)
    except RequestError as error:
        print(f"First not finished: {error}")

    raw = daemon.request({"cmd": "simulations", "state": "RUNNING"})
    print(f"Raw response: {raw}")

finally:
    daemon.close()
```

## Custom display

### Using the manager

To draw your own display, turn the built-in one off with `display=False` and
call `refresh()` yourself:

```python
from time import sleep

from trnrun import SimulationManager

with SimulationManager(workers=2, display=False) as manager:
    simulations = [
        manager.add(deck, watch_tmp=True)
        for deck in (r"C:\path\to\first.dck", r"C:\path\to\second.dck")
    ]
    while not all(simulation.is_finished for simulation in simulations):
        manager.refresh()
        for simulation in simulations:
            progress = f"{simulation.percent:.0%}" if simulation.percent is not None else "no progress yet"
            print(f"[{simulation.sim_id}] {simulation.deck_file.name}: {progress} ({simulation.status})")
        sleep(1)
```

### Using the daemon

Or follow the simulations with `Daemon`, releasing each one once finished:

```python
from time import sleep

from trnrun import Daemon

decks = (r"C:\path\to\first.dck", r"C:\path\to\second.dck")
with Daemon(workers=2) as daemon:
    for deck in decks:
        daemon.add(deck, watch_tmp=True)
    remaining = len(decks)
    while remaining:
        for simulation in daemon.simulations("RUNNING"):
            print(simulation)
        for simulation in daemon.simulations("FINISHED"):
            print(f"[{simulation.sim_id}] {simulation.deck_file.name}: {simulation.status}")
            daemon.release(simulation.sim_id)
            remaining -= 1
        sleep(1)
```

## Examples

Runnable examples are available
in the [TRNRun repository](https://github.com/NRCan/TRNRun/tree/main/libraries/python/examples).
