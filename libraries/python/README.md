# TRNRun for Python

Run batches of TRNSYS simulations from Python and watch their progress live,
in a terminal or a Jupyter notebook. Requires Windows, Python 3.12 or later,
and the native `trnrund.exe` and `trnrun.exe`. Real simulations also require
TRNSYS.

```sh
pip install trnrun
```

- [Running simulations](#running-simulations) is for scripts and notebooks.
- [Building on trnrund](#building-on-trnrund) is for applications that read
  the database themselves.

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

**Leaving the `with` block interrupts runs that have not finished**, so call
`manager.wait()` inside it.

- `SimulationManager(database_path=None, *, max_concurrent=None,
  refresh_interval=0.1, display=True)` starts the daemon. `max_concurrent`
  defaults to one less than the CPU count. Runs are kept in a temporary
  database; pass `database_path="runs.sqlite3"` to keep them. A reused file
  keeps its earlier runs.
- `add(deck_file, settings=None, *, label=None)` queues a deck and returns its
  `Simulation` at once. The settings are copied, so you can change them
  between calls.
- `wait(simulation=None, *, timeout=None)` blocks until that run has
  finished, or every run.
- `cancel(simulation)` stops a queued or running run; it finishes as
  `CANCELLED`.
- `active` lists the unfinished runs.

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

Pass `display=False` and read the handles from your own timer. The manager
keeps them up to date in the background, and reading never blocks:

```python
manager = SimulationManager(display=False)
simulation = manager.add("model.dck", settings)

def on_timer():
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
| `SyncError` | The manager could not read the database; the cause is chained | `RuntimeError` |
| `SchemaVersionError` | A database from another trnrund version | `ValueError` |

A missing executable raises `FileNotFoundError`, and an unanswered request
raises `TimeoutError`. If trnrund crashes, `manager.wait()` raises
`DaemonExitedError` instead of hanging.

## Building on trnrund

`trnrund` saves every run, its progress, and its TRNSYS logs to a SQLite
database. `Daemon` starts it and submits runs; you read the database with
plain SQL. The [daemon documentation](../../components/trnrund/README.md)
describes the [schema](../../components/trnrund/README.md#reading-the-database)
and how to poll it.

```python
from contextlib import closing

from trnrun import Daemon

with Daemon("runs.sqlite3", max_concurrent=4) as daemon, closing(daemon.connect()) as db:
    run_id = daemon.add("model.dck", ["--watchTmp:true"], label="case A")

    revision = daemon.start_revision  # Only this daemon's changes.
    finished = False
    while not finished:
        daemon.wait_for_changes(revision)  # Blocks; raises DaemonExitedError if trnrund crashed.
        for row in db.execute("SELECT * FROM runs WHERE revision > ? ORDER BY revision", (revision,)):
            revision = row["revision"]
            finished |= row["run_id"] == run_id and row["state"] == "FINISHED"

    print(db.execute("SELECT trnrun_status, succeeded, error FROM runs WHERE run_id = ?", (run_id,)).fetchone())
```

`Daemon(database_path=None, *, max_concurrent=None, trnrund_path=...,
trnrun_path=..., request_timeout=60.0)`:

- `add(deck_file, trnrun_args=(), *, label=None) -> int` submits a deck and
  returns its run ID once saved, not finished. `trnrun_args` is a
  `SimulationSettings` or raw TRNRun options.
- `cancel(run_id)` stops a queued or running run.
- `shutdown(*, cancel_running=False, timeout=None)` cancels queued runs, waits
  for running ones, and waits for trnrund to exit.
- `close()`, also called when leaving a `with` block, interrupts unfinished
  runs and deletes a temporary database.
- `connect()` opens the database read-only, with rows readable by column name.
- `wait_for_changes(after_revision, timeout=None) -> bool` blocks until
  trnrund saves a revision after `after_revision`, and returns `False` only
  on timeout. It returns at once if a newer revision was already announced, so
  a change saved while you were querying is never missed. Once trnrund has exited and nothing newer was saved, it raises
  `ClosedError` after `shutdown()`/`close()` and `DaemonExitedError` after a
  crash, so a loop like the one above never hangs.
- `database_path`, `session_id`, `start_revision`, and `start_log_id` come
  from trnrund's `ready` reply.

Every `Daemon` method is safe from any thread. A SQLite connection belongs to
the thread that opened it. Open it while the daemon runs and keep it: right
after a crash, a new connection can fail to open.

### Optional helpers

These turn rows into typed records, if you want them; like everything above,
they are importable from `trnrun`:

- `connect(path)` opens any trnrund database read-only, with or without a
  daemon, and checks its schema version.
- `read_changes(connection, after_revision=0, after_log_id=0) -> Changes`
  reads the runs and logs saved after those positions, from one snapshot.
  `changes.runs` are `SimulationInfo`s, `changes.logs` are `LogEvent`s, and
  `changes.revision`/`changes.log_id` are where to read next.
- `parse_run(row)` and `parse_log(row)` turn a `SELECT *` row of `runs` or
  `logs` into a `SimulationInfo` or `LogEvent`. Fields are named after their
  columns and are `None` where the column is `NULL`.

[`examples/example_gui.py`](examples/example_gui.py) is a tkinter dashboard
built this way.

## Database safety

The daemon never deletes runs or logs. Keep the database on a local disk; its
directory must already exist. Only one daemon may own a database at a time. A
database from another schema version is refused; start a new file.

## Native executables and packaging

This source package does not build native executables. Deploy both components
using their existing `nimble deploy` tasks, or pass `trnrun_path` and
`trnrund_path` when constructing `Daemon` or `SimulationManager`. The wheel
build hook requires both executables in `trnrun/bin` and checks that their
versions match the Python package version.
