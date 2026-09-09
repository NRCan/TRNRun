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

Run a folder of decks with bounded concurrency and worker-pickup backpressure:

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

## Admission and backpressure

`SimulationManager.add()` writes one request to `trnrunq` and blocks until a
worker picks it up and emits `QUEUE/ACCEPTED`, before launching the runner.
When all workers are busy, `add()` waits for worker pickup, providing
caller-side backpressure. There is no configurable pending backlog.

The queue owns the concurrency; this library is its synchronous client and runs
nothing in the background. Simulation state therefore advances only while a call
into the manager is reading queue stdout: `add()` reads until its own request is
picked up, and `wait()` and `follow()` read until the accepted runs finish.
Between those calls, state is frozen — poll `is_finished` in a bare `sleep` loop
and it will never change. Use `follow()` to drive progress reporting instead.
Long pauses between calls can also fill the stdout pipe and stall the queue.
Drive the manager from one thread; it has no background reader or synchronization.

The manager registers each `runId` after sending its request and before reading
stdout. With no background reader, incoming events stay buffered until registration
is complete, and a failed send leaves no registered simulation. The queue guarantees
`QUEUE/ACCEPTED` before any runner output or `QUEUE/COMPLETED` for that request.
The display shows only the latest JSONL `STATUS` value, leaving the status column
blank until one arrives. Completion does not replace that value with a synthetic
label, even if the runner exited without a terminal status. `PENDING` and
`LAUNCHING` come from the runner's launch-mutex and process-launch stages. If queue stdout closes before an acknowledgment, `add()`
raises `RuntimeError` rather than waiting indefinitely.

## Completion and results

A runner reports its outcome through one of these terminal `STATUS` values:

| Status | Meaning |
| --- | --- |
| `DONE` | Completed successfully. |
| `ERROR` | Failed during launch or execution, or reported a fatal error. |
| `CANCELLED` | The runner stopped before completing the simulation. |
| `TIMEOUT` | Exceeded a configured detection or monitoring timeout. |
| `STALLED` | Simulation progress stopped for longer than `stall_timeout_ms`. |

`DONE` is the only successful terminal status. The queue then emits
`QUEUE/COMPLETED` after the child exits; this process boundary sets
`Simulation.is_finished` and releases `wait()`. Completion decides only that the
run is over, never its outcome, so a run that exited without a terminal status
finishes without ever reaching `succeeded`. `has_terminal_status` distinguishes
a reported outcome from a runner that stopped without one. Finalized simulation
state is unchanged by duplicate completion or subsequent runner events.

`Simulation.completion_event` retains the queue's completion metadata, including
`exit_code`, without changing status-based success. A completion event with a
null exit code means the runner could not be launched. No completion event means
the run has not been marked finished.

If queue stdout closes with submissions still awaiting acceptance or completion,
`add()`, `follow()`, `wait()`, or `shutdown()` raises `RuntimeError` listing the
outstanding run IDs. Shutdown still reaps the queue, including when premature EOF
was already reported by another manager call. If all completion events were
received, a nonzero queue exit code is reported at shutdown (including context
exit). Queue errors do not fabricate simulation outcomes: unfinished runs retain
their last events and remain unfinished, rather than appearing in `failed`.
Queue-crash recovery and automatic retries are not supported.

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
| `trnrunq_path` | bundled queue | Queue executable path, primarily for development and testing. |

| Member | Description |
| --- | --- |
| `add(deck_file, config)` | Submit a deck, block until worker pickup before launch, and return its `Simulation`. |
| `wait(simulation=None)` | Block until the selected simulation finishes, or all simulations when omitted; raise on premature queue EOF. Returns `None`; has no timeout. |
| `follow()` | Iterate simulations as queue output updates them, ending when every accepted run has finished; raise on premature queue EOF. |
| `simulations` | All queue-accepted simulations in acceptance order. |
| `succeeded` | Simulations whose terminal status is `DONE`. |
| `failed` | Finished simulations that did not succeed, whether they reported a terminal status or were cut off. |
| `shutdown()` | Close queue input, drain output, and reap the queue; report premature EOF or a nonzero queue exit code. Call only once. |

Use each `SimulationManager` in a single `with` block. Leaving the context closes
queue input, drains stdout to EOF, and waits for the queue process to exit.
Do not call `shutdown()` inside that block or reuse the manager afterward;
repeated shutdown and operations after shutdown are not guarded or supported.
Simulation results remain readable after context exit. Without a `with` block,
the caller must call `shutdown()` exactly once.

Pass a simulation returned by this manager's `add()` to wait for only that run:

```python
with SimulationManager(max_concurrent=2) as manager:
    first = manager.add(decks[0], config)
    second = manager.add(decks[1], config)
    manager.wait(first)
    print(f"first succeeded: {first.succeeded}")
    manager.wait()  # Finish any remaining runs.
```

`wait(simulation)` continues applying events for every run while waiting, but
returns as soon as the selected run receives `QUEUE/COMPLETED`, not merely a
terminal runner status. An already-finished simulation returns immediately;
a simulation not owned by this manager raises `ValueError`. Other runs may
still be active afterward: keep consuming events with `wait()` or `follow()`.
Leaving the manager context still drains and waits for all remaining runs.

`wait()` no longer accepts `timeout` or returns a boolean. Remove the timeout
argument from existing calls and inspect `succeeded` and `failed` after waiting. Runner timeouts remain configurable through `SimulationConfig`;
they govern runner behavior rather than bounding a Python manager call.

## `Simulation`

A `Simulation` is a view of one run submitted through `SimulationManager.add()`.
It is mutated only while a manager call is reading queue stdout, on the calling
thread, and is not synchronized: read it from the thread that drives the
manager. Between manager calls its state is frozen, so fields read together are
consistent without any extra ceremony.

| Member | Description |
| --- | --- |
| `id` | Identifier assigned by the manager and used as the queue `runId`. |
| `deck_path` | Submitted deck path. |
| `config` | Configuration submitted with the deck. |
| `status` | Latest `STATUS` event. |
| `progress` | Latest `PROGRESS` event; requires `watch_tmp=True`. |
| `config_event` | Latest simulation start, stop, and step event. |
| `setting_event` | Latest runner settings event. |
| `completion_event` | Queue completion event, including its `exit_code`, or `None` if none was received. |
| `logs` | Retained log events. |
| `notices`, `warnings`, `fatals` | Log severity counters for the complete run. |
| `is_running` | Whether the simulation is waiting or running. |
| `is_accepted` | Whether a queue worker picked the simulation up. |
| `is_finished` | Whether the queue reported completion for this run. |
| `has_terminal_status` | Whether the runner reported a canonical terminal status. |
| `succeeded` | Whether the completed run has terminal status `DONE`. |

Simulation outcome comes from runner `STATUS` events; process completion comes
from the queue's `QUEUE/COMPLETED` event.

## Monitoring progress

Set `watch_tmp=True` to receive progress events. The built-in terminal display is
enabled by default; set `refresh_interval=0` to disable it when providing custom
output.

`follow()` reads the queue and yields each simulation as an event updates it,
ending once every accepted run has finished. Report from there rather than from
a sleep loop, which cannot make progress while the manager is idle. It does not
replay updates already consumed by `add()`, `wait()`, or another iteration.

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
