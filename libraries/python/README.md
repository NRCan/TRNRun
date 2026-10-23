# TRNRun for Python

Run batches of TRNSYS simulations from Python and watch their progress live,
in a terminal or a Jupyter notebook. Requires Windows, Python 3.12 or later,
and the native `trnrund.exe` and `trnrun.exe`. Real simulations also require
TRNSYS.

```sh
pip install trnrun
```

- [Running simulations](#running-simulations) is for scripts and notebooks.
- [Building on trnrund](#building-on-trnrund) is for applications that poll
  the daemon themselves.

## Running simulations

```python
from trnrun import SimulationManager, SimulationSettings

settings = SimulationSettings(trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe", watch_tmp=True)

with SimulationManager(max_concurrent=4) as manager:
    simulations = [manager.add(deck, settings) for deck in ["a.dck", "b.dck", "c.dck"]]
    manager.wait()  # Returns once every run has finished, failed ones included.

for simulation in simulations:
    print(simulation.run_id, simulation.deck_file.name, simulation.succeeded, simulation.status)
    for log in simulation.logs:
        if log.severity == "Fatal":
            print("   ", log.time, log.message)
```

While it runs, each running simulation has a live line, and each finished one
is printed once:

```text
[1] …\decks\model.dck | Status: DONE       | Logs: N:2 W:1 F:0  | Elapsed: 00:01:12 | ETA: 00:00:00 | [####################]  8,760 /  8,760 (100%)
```

**Leaving the `with` block cancels runs that have not finished**, so call
`manager.wait()` inside it.

Nothing runs in the background: the handles and the display change only
while `wait()` or `refresh()` runs. In a notebook, a cell that adds runs and
returns shows no progress until a later cell calls `manager.wait()`.

- `SimulationManager(*, max_concurrent=None, refresh_interval=1.0,
  display=True)` starts the daemon. `max_concurrent` defaults to one less
  than the CPU count. Runs are kept in trnrund's memory, never on disk, and
  dropped from it once the manager has their final state.
- `add(deck_file, settings=None, *, label=None, wait_for="QUEUED")` queues a
  deck and returns its `Simulation`, at once by default, or once it reaches
  `wait_for`. The settings are copied, so you can change them between calls.
- `wait(simulation=None, *, timeout=None)` blocks until that run has
  finished, or every run, refreshing every `refresh_interval` seconds.
- `refresh()` syncs every handle and the display once, without waiting.
- `cancel(simulation)` stops a queued or running run; it finishes as
  `CANCELLED`.
- `shutdown()`, also called when leaving a `with` block, cancels unfinished
  runs, collects their final state, then stops the daemon.
- `active` lists the unfinished runs.

Call every manager method from one thread.

A `Simulation` stays readable after the manager shuts down:

| Attribute | Meaning |
| --------- | ------- |
| `run_id`, `deck_file`, `settings` | What was submitted |
| `state` | `QUEUED`, `RUNNING`, or `FINISHED`: where the run is |
| `status` | TRNRun's latest status, such as `DONE` or `ERROR`: how it went |
| `succeeded` | `True` or `False` once finished; `None` before |
| `error` | Why the run was stopped, such as a cancel; `None` if not |
| `progress` | `percent` from 0 to 1, simulated `time`, `elapsed_ms`, `eta_ms` |
| `notices`, `warnings`, `fatals`, `logs` | TRNSYS log entries |
| `info` | Everything above and more, such as `exit_code`, `status_message`, timestamps |

### In a GUI

Pass `display=False`, and call `refresh()` from your own timer before
reading the handles. Each refresh is one request to the daemon:

```python
manager = SimulationManager(display=False)
simulation = manager.add("model.dck", settings)

def on_timer():
    manager.refresh()
    progress = simulation.progress
    progress_bar.set(progress.percent if progress else 0)
```

Any object with `update(changed)` and `close()` methods can also be passed as
`display=`.

## Simulation settings

`SimulationSettings` names and types every TRNRun option for editor
autocomplete. Use `help(SimulationSettings)` for all options, their units, and
effects.

```python
settings = SimulationSettings(
    trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe",
    watch_tmp=True,
    watch_timeout_ms=3_600_000,
    kill_on_timeout=True,
)
```

Every field defaults to `None`, which keeps TRNRun's own default; run
`trnrun.exe --help` for those. A set `trnexe_path` must exist. Other values are
checked by TRNRun's own parser when the run is added, so a typo fails at once.

## Errors

Every error trnrun raises itself is a `TrnrunError`, importable from `trnrun`:

| Error | Raised when | Also a |
| ----- | ----------- | ------ |
| `DaemonExitedError` | trnrund crashed or failed to start; has `exit_code` and `diagnostics` | `RuntimeError` |
| `RequestRejectedError` | trnrund refused a run, such as a missing deck or a bad option | `ValueError` |
| `ClosedError` | The manager or daemon was already closed | `RuntimeError` |
| `ProtocolError` | trnrund wrote something other than the reply; the daemon is then closed | `RuntimeError` |
| `ProtocolVersionError` | trnrund speaks another protocol version | `ValueError` |

A missing executable raises `FileNotFoundError`. Requests have no timeout,
since a crashed trnrund ends the read at once: `manager.wait()` then raises
`DaemonExitedError` instead of hanging.

## Building on trnrund

`trnrund` keeps every run, its progress, and its TRNSYS logs in memory, and
answers for them over its stdin and stdout. `Daemon` starts it, submits runs,
and asks for their state, returned as `SimulationInfo` records that hold
their `LogEvent` logs. Each call is one request, on your own thread; nothing runs in the
background. The [daemon documentation](../../components/trnrund/README.md)
describes the [protocol](../../components/trnrund/README.md#request-protocol)
and [how to follow runs](../../components/trnrund/README.md#following-runs).

```python
import time

from trnrun import Daemon

with Daemon(max_concurrent=4) as daemon:
    run = daemon.add("model.dck", ["--watchTmp:true"], label="case A")

    while not run.is_finished:
        time.sleep(1)
        run = daemon.get(run.run_id)  # Raises DaemonExitedError if trnrund crashed.

    for log in run.logs:
        print(log.severity, log.message)
    print(run.status, run.succeeded, run.error)
    daemon.release(run.run_id)
```

`Daemon(*, max_concurrent=None, trnrund_path=..., trnrun_path=...)`:

- `add(deck_file, trnrun_args=(), *, label=None, wait_for="QUEUED") ->
  SimulationInfo` submits a deck and returns its run, at once by default.
  With `wait_for="RUNNING"` or `"FINISHED"` it blocks until the run gets
  there, and the run returned is then its outcome. `trnrun_args` is a
  `SimulationSettings` or raw TRNRun options.
- `get(run_id) -> SimulationInfo` returns one run with every log entry so
  far in `logs`, oldest first.
- `release(run_id)` deletes a finished run from trnrund once you have what
  you need. trnrund keeps every run until then, so release them as they
  finish in a long batch.
- `cancel(run_id)` stops a queued or running run.
- `shutdown(*, cancel_running=False)` cancels queued runs and refuses new
  ones; trnrund keeps answering, so you can still collect the last results.
- `close()`, also called when leaving a `with` block, stops trnrund, killing
  unfinished runs and dropping every run it held.

Every `Daemon` method is safe from any thread: requests take turns, so an
`add` that waits holds the others back.

`parse_run(run)` turns a run object of a reply into a `SimulationInfo`, logs
included, for clients that speak to trnrund themselves.

[`examples/example_gui.py`](examples/example_gui.py) is a tkinter dashboard
built this way.

## Native executables and packaging

This source package does not build native executables. Deploy both components
using their existing `nimble deploy` tasks, or pass `trnrun_path` and
`trnrund_path` when constructing `Daemon` or `SimulationManager`. The wheel
build hook requires both executables in `trnrun/bin` and checks that their
versions match the Python package version.
