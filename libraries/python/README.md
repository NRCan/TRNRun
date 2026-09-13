# TRNRun

`trnrun` runs and monitors TRNSYS simulations from Python. Each
`SimulationManager` owns one bundled `trnrunq.exe` process, which queues requests
and launches the bundled `trnrun.exe` runner with bounded concurrency. Events
from every runner are routed back to `Simulation` objects.

## Requirements

- Windows
- Python >= 3.12
- TRNSYS v17 or v18
- Optional: Progress Tracker (Type3830) for progress events

## Installation

```sh
pip install trnrun
```

The Windows package includes both `trnrun.exe` and `trnrunq.exe`.

## Quick start

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", config)
    manager.wait()

status = simulation.status.status if simulation.status is not None else "UNKNOWN"
print(f"{simulation.deck_path}: {status}")
```

Run a folder of decks with bounded concurrency:

```python
from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)
decks = sorted(Path(r"C:\path\to\dck").glob("*.dck"))

with SimulationManager(max_concurrent=4) as manager:
    simulations = [manager.add(deck, config) for deck in decks]
    manager.wait()

for simulation in simulations:
    status = simulation.status.status if simulation.status is not None else "UNKNOWN"
    print(f"{simulation.deck_path}: {status}")
```

`add()` waits for an available worker before returning. Drive the manager from
one thread: simulation state updates only during `add()`, `wait()`, or `follow()`.
Use `follow()` for live monitoring rather than polling in a sleep loop.

## Completion and results

A runner reports its outcome through one of these terminal `STATUS` values:

| Status | Meaning |
| --- | --- |
| `DONE` | Completed successfully. |
| `ERROR` | Failed during launch or execution, or reported a fatal error. |
| `CANCELLED` | The runner stopped before completing the simulation. |
| `TIMEOUT` | Exceeded a configured detection or monitoring timeout. |
| `STALLED` | Simulation progress stopped for longer than `stall_timeout_ms`. |

A run succeeds only after it finishes with status `DONE`. After `wait()`, use
`manager.succeeded` and `manager.failed` to inspect results. A finished run without
a terminal status is considered failed.

Queue failures raise `RuntimeError`; unfinished runs remain unfinished and are
not automatically retried.

```python
with SimulationManager(max_concurrent=4) as manager:
    for deck in decks:
        manager.add(deck, config)
    manager.wait()

    for simulation in manager.succeeded:
        print(f"completed: {simulation.deck_path}")

    for simulation in manager.failed:
        status = simulation.status
        label = status.status if status is not None else ""
        print(f"failed: {simulation.deck_path} ({label})")

```

## `SimulationManager`

```python
SimulationManager(
    max_concurrent=DEFAULT_MAX_CONCURRENT,
    refresh_interval=1.0,
)
```

| Parameter | Default | Description |
| --- | --- | --- |
| `max_concurrent` | `cpu_count() - 1`, at least 1 | Maximum number of active runners. |
| `refresh_interval` | `1.0` | Minimum seconds between display redraws, which the manager issues as it reads the queue. A non-positive value disables the display. |
| `trnrunq_path` | bundled queue | Keyword-only queue executable path, primarily for development and testing. |

| Member | Description |
| --- | --- |
| `add(deck_file, config)` | Submit a deck, block until worker pickup before launch, and return its `Simulation`. |
| `wait(simulation=None)` | Wait for one simulation, or all when omitted. Returns `None`; has no timeout. |
| `follow()` | Yield updated simulations until all runs finish. |
| `simulations` | All queue-accepted simulations in acceptance order. |
| `succeeded` | Finished simulations whose terminal status is `DONE`. |
| `failed` | Finished simulations that did not succeed. |
| `shutdown()` | Finish remaining runs and close the queue. Called automatically on context exit. |

Use each manager in a single `with` block. Context exit waits for remaining runs
and closes the queue; results remain readable afterward. Do not reuse the manager
or call `shutdown()` inside the block. Without a context, call `shutdown()` exactly once.

Pass a simulation returned by this manager's `add()` to wait for only that run:

```python
with SimulationManager(max_concurrent=2) as manager:
    first = manager.add(decks[0], config)
    second = manager.add(decks[1], config)
    manager.wait(first)
    print(f"first succeeded: {first.succeeded}")
    manager.wait()  # Finish any remaining runs.
```

`wait(simulation)` still updates other runs while waiting. The selected simulation
must belong to this manager; other runs may still be active when it returns.

## `Simulation`

A `Simulation` holds the state and results of one submitted run.

| Member | Description |
| --- | --- |
| `id` | Identifier assigned by the manager and used as the queue `runID`. |
| `deck_path` | Absolute submitted deck path. |
| `config` | Per-run copy of the submitted configuration. |
| `status` | Latest status event, with an optional outcome or failure message. |
| `progress` | Latest `PROGRESS` event; requires `watch_tmp=True`. |
| `config_event` | Latest simulation start, stop, and step event. |
| `setting_event` | Latest runner settings event. |
| `completion_event` | Queue completion event, including its `exit_code`, or `None` if none was received. |
| `logs` | Snapshot of the latest 5,000 received log events, oldest first. |
| `log_count` | Total received log events, including entries no longer retained in `logs`. |
| `notices`, `warnings`, `fatals` | Received log severity counters, including entries no longer retained in `logs`. |
| `is_running` | Whether the simulation is waiting or running. |
| `is_accepted` | Whether a queue worker picked the simulation up. |
| `is_finished` | Whether the queue reported completion for this run. |
| `has_terminal_status` | Whether the runner reported a canonical terminal status. |
| `succeeded` | Whether the completed run has terminal status `DONE`. |

See [`trnrun.events`](trnrun/events.py) for event fields and units.

## Monitoring progress

Progress events require `watch_tmp=True` and Type3830 in the deck. The built-in
terminal display is enabled by default; set `refresh_interval=0` for custom output.

`follow()` yields simulations as they update until all runs finish. It does not
replay updates already consumed by another manager call.

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1, refresh_interval=0) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", config)

    for updated in manager.follow():
        if updated.progress is not None:
            print(f"[{updated.id}] {updated.progress.percent:6.1%}", end="\r")

status = simulation.status.status if simulation.status is not None else "UNKNOWN"
print(f"\nstatus: {status}")
```

## `SimulationConfig`

`SimulationConfig` controls runner behavior, including the TRNSYS executable
path, launch detection, log and progress monitoring, timeouts, cleanup, severity
filtering, and event-file output. Its defaults match the runner defaults.
See [`SimulationConfig`](trnrun/config.py) for the complete field reference.

Set `trnexe_path` if TRNSYS is installed somewhere other than
`C:\TRNSYS18\Exe\TrnEXE64.exe`. To stop TRNSYS on timeout or stall, enable the
corresponding kill option; timeouts alone do not bound `wait()`.

For example:

```python
from pathlib import Path

from trnrun import SimulationConfig

config = SimulationConfig(
    trnexe_path=Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe"),
    watch_tmp=True,
    watch_timeout_ms=300_000,
    stall_timeout_ms=300_000,
    kill_on_timeout=True,
    kill_on_stall=True,
    clean_on_success=True,
)
```
