# TRNRun

`trnrun` runs and monitors TRNSYS simulations from Python. Each `SimulationManager` owns one bundled
`trnrunq.exe` process, which queues requests and launches the bundled `trnrun.exe` runner with bounded
concurrency. Events from every runner are routed back to thread-safe `Simulation` objects.

## Requirements

- Windows
- Python >= 3.12
- TRNSYS v17 or v18
- Optional: Progress Tracker (Type3830) for progress events

## Installation

```sh
pip install trnrun
```

The package includes both `trnrun.exe` and `trnrunq.exe`.

## Quick start

```python
from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1, max_pending=0) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", config)
    manager.wait()

status = simulation.status.status if simulation.status is not None else "UNKNOWN"
print(f"{simulation.deck_path}: {status}")
```

Run a folder of decks with bounded concurrency and a bounded pending queue:

```python
from pathlib import Path

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)
decks = sorted(Path(r"C:\path\to\dck").glob("*.dck"))

with SimulationManager(max_concurrent=4, max_pending=16) as manager:
    simulations = [manager.add(deck, config) for deck in decks]
    manager.wait()

for simulation in simulations:
    status = simulation.status.status if simulation.status is not None else "UNKNOWN"
    print(f"{simulation.deck_path}: {status}")
```

## Completion and results

A simulation is complete when it receives a terminal `STATUS` event. The terminal statuses are:

| Status | Meaning |
| --- | --- |
| `DONE` | Completed successfully. |
| `ERROR` | Failed during launch or execution, or reported a fatal error. |
| `CANCELLED` | The runner stopped before completing the simulation. |
| `TIMEOUT` | Exceeded a configured detection or monitoring timeout. |
| `STALLED` | Simulation progress stopped for longer than `stall_timeout_ms`. |

`DONE` is the only successful terminal status. `Simulation.is_finished` and `Simulation.succeeded` are
derived from these status events. `SimulationManager.succeeded` and `SimulationManager.failed` return
the corresponding completed simulations.

```python
with SimulationManager(max_concurrent=4, max_pending=16) as manager:
    for deck in decks:
        manager.add(deck, config)
    manager.wait()

    for simulation in manager.succeeded:
        print(f"completed: {simulation.deck_path}")

    for simulation in manager.failed:
        status = simulation.status.status if simulation.status is not None else "UNKNOWN"
        print(f"failed: {simulation.deck_path} ({status})")
```

## `SimulationManager`

```python
SimulationManager(
    max_concurrent=DEFAULT_MAX_CONCURRENT,
    max_pending=0,
    refresh_interval=1.0,
)
```

| Parameter | Default | Description |
| --- | --- | --- |
| `max_concurrent` | `cpu_count() - 1`, at least 1 | Maximum number of runners active at once. |
| `max_pending` | `0` | Maximum requests waiting for a runner. `0` means unlimited. |
| `refresh_interval` | `1.0` | Seconds between display updates. A non-positive value disables the display. |

| Member | Description |
| --- | --- |
| `add(deck_file, config)` | Submit a deck and return its `Simulation`. |
| `wait(timeout=None)` | Wait for simulations submitted before the call. Returns `True` if all reached terminal statuses. |
| `simulations` | All submitted simulations in creation order. |
| `succeeded` | Simulations whose terminal status is `DONE`. |
| `failed` | Simulations with another terminal status. |
| `shutdown()` | Stop accepting requests and drain all accepted work. |

Use `SimulationManager` as a context manager whenever possible. Leaving the context closes queue input
and waits for accepted simulations to finish.

## `Simulation`

A `Simulation` is a thread-safe view of one submitted run. Create simulations with
`SimulationManager.add()`.

Useful members include:

| Member | Description |
| --- | --- |
| `id` | Identifier assigned by the manager. |
| `deck_path` | Submitted deck path. |
| `config` | Configuration submitted with the deck. |
| `status` | Latest `STATUS` event. |
| `progress` | Latest `PROGRESS` event; requires `watch_tmp=True`. |
| `config_event` | Latest simulation start, stop, and step event. |
| `setting_event` | Latest runner settings event. |
| `logs` | Retained log events. |
| `notices`, `warnings`, `fatals` | Log severity counters for the complete run. |

| `is_running` | Whether the latest status represents active work. |
| `is_finished` | Whether a terminal status was received. |
| `succeeded` | Whether the terminal status is `DONE`. |
| `snapshot()` | Read the simulation fields as one consistent snapshot. |

Success and completion come from `STATUS` events rather than queue or child-process bookkeeping.

## Monitoring progress

Set `watch_tmp=True` to receive progress events. The built-in terminal display is enabled by default;
set `refresh_interval=0` to disable it when providing your own output.

```python
import time

from trnrun import SimulationConfig, SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=1, max_pending=0, refresh_interval=0) as manager:
    simulation = manager.add(r"C:\path\to\deck.dck", config)

    while not simulation.is_finished:
        snapshot = simulation.snapshot()
        if snapshot.progress is not None:
            print(f"{snapshot.progress.percent:6.1%}", end="\r")
        time.sleep(1.0)

status = simulation.status.status if simulation.status is not None else "UNKNOWN"
print(f"\nstatus: {status}")
```

## `SimulationConfig`

`SimulationConfig` controls runner behavior, including the TRNSYS executable path, launch detection,
log and progress monitoring, timeouts, cleanup, severity filtering, and event-file output. Its defaults
match the runner defaults. For example:

```python
from pathlib import Path

from trnrun import SimulationConfig

config = SimulationConfig(
    trnexe_path=Path(r"C:\TRNSYS18\Exe\TrnEXE64.exe"),
    watch_tmp=True,
    watch_timeout_ms=300_000,
    stall_timeout_ms=300_000,
    clean_on_success=True,
)
```
