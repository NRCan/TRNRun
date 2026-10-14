# TRNRun for Python

A thin wrapper for the Windows `trnrund` daemon, plus a simulation manager
with an optional live progress display built on Rich.
Requires Python 3.12 or later and the native `trnrund.exe` and `trnrun.exe`.
Real simulations also require TRNSYS.

```sh
pip install trnrun            # Daemon, Database, SimulationConfig, SimulationManager
pip install trnrun[display]   # adds Rich, for the manager's built-in progress display
```

Just want to launch a batch and watch it? Skip to the
[simulation manager](#simulation-manager), which needs no polling code.

```python
from trnrun import Daemon, SimulationConfig

config = SimulationConfig(watch_tmp=True)

with Daemon("runs.sqlite3", max_concurrent=2) as daemon:
    run_id = daemon.add("model.dck", config)

    finished = None
    while finished is None:
        changes = daemon.wait()  # Blocks until trnrund saves something; raises if it crashed.
        finished = next((run for run in changes.runs if run.run_id == run_id and run.is_finished), None)

    print(finished.succeeded, finished.status)
    logs = daemon.database.get_logs(run_id)
```

## API

- `Daemon(database_path="trnrund.sqlite3", *, max_concurrent=None,
  trnrun_path=None, executable=..., request_timeout=60.0)` starts the daemon,
  waits for its `ready` reply, and opens its database. Its change
  notifications are read from then on.
  - `database_path` is created if missing; its directory must exist. An
    existing database keeps its runs and logs, and the daemon continues its
    run numbers in a new session. For an empty history, use a new file.
  - `max_concurrent` limits simulations running at once; `None` means
    `max(CPUs - 1, 1)`.
  - `trnrun_path` is the TRNRun runner; `None` means `trnrun.exe` beside
    the daemon executable.
  - `executable` defaults to `trnrun/bin/trnrund.exe` inside the package,
    with `trnrun.exe` beside it. To use an existing build, pass
    `executable=r"C:\path\to\trnrund.exe"` and, if needed,
    `trnrun_path=r"C:\path\to\trnrun.exe"`.
  - A request that gets no reply within `request_timeout` seconds raises
    `TimeoutError`.

  Relative paths resolve from Python's current working directory.
- `add(deck_file, trnrun_args=(), *, label=None) -> int` submits a run and
  returns the run ID the daemon assigned. Run IDs are integers never reused
  in a database. `trnrun_args` is a `SimulationConfig` or raw CLI arguments;
  omitting it keeps the runner's defaults. `label` is an optional tag saved
  with the run. A relative `deck_file` resolves from Python's working
  directory at the time of the call. The call returns once the run is saved,
  not when it starts. Rejected runs raise `ValueError`; a request to a daemon
  that has exited raises `RuntimeError` with its exit code and stderr message,
  such as `trnrund exited with code 2: 'maxConcurrent' must be at least 1`.
- `cancel(run_id)` stops one run and returns once the daemon has recorded the
  request. A queued run is already `FINISHED` with `trnrun_status`
  `CANCELLED` on return. A running one has its TRNRun killed, along with
  TRNSYS, and becomes `FINISHED`/`CANCELLED` shortly after. Its `error` tells
  which: `Not started: cancelled by the client` or `Interrupted: cancelled by
  the client`. Cancelling a finished run changes nothing. An unknown `run_id`
  raises `ValueError`.
- `wait(timeout=None) -> Changes` blocks until the daemon announces newly
  saved changes, then returns them: `changes.runs`, the latest
  `SimulationInfo` of each run that changed, and `changes.logs`, the new
  `LogEvent`s. It returns at once if changes are already waiting, and an empty
  `Changes` after `timeout` seconds. It starts with what this daemon changes,
  not the database's earlier history.
- `poll() -> Changes` returns the same without blocking, for timers such as a
  GUI's.
- Both raise `RuntimeError` once the daemon has exited unexpectedly **and**
  every change it saved has been returned, so a loop over them never hangs on
  a crashed daemon and never misses its last saves. `check()` raises the same
  error without reading anything.
- `shutdown(*, cancel_running=False, timeout=None)` cancels queued runs, waits
  for running ones, and waits for the daemon to exit. With
  `cancel_running=True`, running runs are killed instead. If they still run
  after `timeout` seconds, the daemon is told to stop at once, which saves
  them as interrupted. The database stays readable until `close()`.
- `close()` closes stdin, waits for the daemon to exit, **interrupting
  unfinished simulations**, then closes the database. It is safe to call more
  than once, including after the daemon crashed. Leaving a `with` block calls
  `close()`; wait for your runs inside the block.
- `database_path` is the path returned by the daemon, `session_id` the
  session its runs are recorded in, and `database` a [`Database`](#reading-the-database)
  that `wait()` and `poll()` read through.

Requests may be sent from any thread. `database`, `poll()`, and `wait()`
belong to the thread that created the daemon; another thread opens its own
`Database` and calls `daemon.wait_for_change(database.revision)` to block.

A run finishes when its `state` is `FINISHED`; check `succeeded` to
distinguish success from failure. See the
[daemon documentation](../../components/trnrund/README.md) for the protocol,
the complete database schema, and CLI options.

## Reading the database

`Database` reads a trnrund database, with or without a running daemon, and
without TRNSYS. It returns typed records.

```python
from trnrun import Database, SimulationState

with Database("runs.sqlite3") as database:
    print(database.count_runs_by_state())

    for run in database.get_runs(state=SimulationState.FINISHED):
        print(run.run_id, run.label, run.succeeded, run.status)

    changes = database.poll()  # Everything so far; later polls return only what is new.
```

- `Database(path, *, after_revision=0, after_log_id=0)` opens an existing
  database read-only. It does not create or migrate one; the schema version
  must be `3`, or it raises `ValueError` after closing. Native SQLite errors
  propagate. A `with` block closes it; so does `close()`.
- `poll() -> Changes` returns the runs and logs saved since the previous
  poll, read from one consistent snapshot, and advances past them. The first
  poll starts after `after_revision` and `after_log_id`; `seek_end()` skips
  everything saved so far. The positions are readable as `revision` and
  `log_id`. Runs are latest snapshots, not an event history: intermediate
  states between polls can be skipped.
- `get_run(run_id)` returns a `SimulationInfo`, or `None` for an unknown ID.
- `get_logs(run_id)` returns its `LogEvent`s, oldest first.
- `get_runs(*, session_id=None, state=None)` returns the runs of one session,
  in one state, or both, in the order they last changed.
- `count_runs_by_state(*, session_id=None)` returns a dict such as
  `{QUEUED: 40, RUNNING: 2, FINISHED: 103}`, with every state present.
- `execute(sql, parameters=())` runs a custom query and returns a
  `sqlite3.Cursor` of `sqlite3.Row`s. Bind values with `?` parameters rather
  than formatting them into SQL.

Like any SQLite connection, a `Database` belongs to the thread that opened it.

### Records

- `SimulationInfo` is one run: `run_id`, `state` (`QUEUED`, `RUNNING`,
  `FINISHED`), `session_id`, `label`, `revision`, `deck_file`,
  `trnrun_args`, TRNRun's latest `status` (`StatusEvent`: `status`,
  `message`), `progress` (`ProgressEvent`: `percent` from 0 to 1, simulated
  `time`, `elapsed_ms`, `eta_ms`), `config` (`ConfigEvent`: simulated
  `start`, `stop`, `step`), `setting` (the settings TRNRun applied, as a
  dict with TRNRun's camelCase keys), `notices`/`warnings`/`fatals`,
  `succeeded`, `exit_code`, `error`, the UTC `submitted_at`/`started_at`/
  `finished_at`, and `is_finished`. Events TRNRun has not reported yet are
  `None`.
- `LogEvent` is one TRNSYS log entry: `log_id`, `run_id`, `severity`
  (`Notice`, `Warning`, `Fatal`), simulated `time`, and, when TRNSYS attaches
  them, `unit_id`, `type_id`, `message_code`, `message`, `information`.

### Common queries

The helpers cover the usual questions; for anything else, query the `runs`
and `logs` tables directly. The
[daemon documentation](../../components/trnrund/README.md#reading-the-database)
describes every column.

```python
# Failed runs and why. Only FINISHED runs have a succeeded value.
failed = database.execute(
    "SELECT run_id, label, trnrun_status, error, fatals FROM runs"
    " WHERE state = 'FINISHED' AND NOT succeeded ORDER BY revision",
).fetchall()

# Wall-clock duration in seconds of each run that started and finished.
durations = database.execute(
    "SELECT run_id, (julianday(finished_at) - julianday(started_at)) * 86400 AS seconds"
    " FROM runs WHERE finished_at IS NOT NULL AND started_at IS NOT NULL",
).fetchall()

# Fatal log entries of one run, with the TRNSYS unit and type that raised them.
fatals = database.execute(
    "SELECT sim_time, unit_id, type_id, message FROM logs"
    " WHERE run_id = ? AND severity = 'Fatal' ORDER BY log_id",
    (1,),
).fetchall()
```

## Simulation configuration

`SimulationConfig` names and types every TRNRun option for editor
autocomplete. Use `help(SimulationConfig)` for all options, their units, CLI
mappings, and effects.

```python
from trnrun import SimulationConfig

config = SimulationConfig(
    trnexe_path=r"C:\TRNSYS18\Exe\TrnEXE64.exe",
    watch_tmp=True,
    watch_timeout_ms=3_600_000,
    kill_on_timeout=True,
)
# Reuse config directly with daemon.add("model.dck", config).
```

Every field defaults to `None`, which passes nothing, so TRNRun's own default
applies; run `trnrun.exe --help` for those defaults. `SimulationConfig()`
therefore passes no options at all. Only TRNRun defines the defaults, so they
cannot drift between TRNRun and this package.

`Daemon.add()` calls `to_cli_args()`, which returns unquoted arguments for the
fields that are set, checks that a set `trnexe_path` exists, and resolves it
from Python's working directory. Boolean fields require actual
`True`/`False`, not strings or integers. The daemon checks the other values
with TRNRun's own parser when the run is added. `Daemon.add()` also accepts
raw CLI argument lists. `poll_ms` controls the runner, not how often Python
reads results.

## Simulation manager

`trnrun.batch` is for scripts and notebooks that just want to launch
simulations and follow them, without polling code.
`SimulationManager` starts the daemon, keeps one `Simulation` handle per run
up to date from a background thread, and shows their progress live.

```python
from trnrun import SimulationConfig
from trnrun.batch import SimulationManager

config = SimulationConfig(watch_tmp=True)

with SimulationManager(max_concurrent=4) as manager:
    simulations = [manager.add(deck, config) for deck in ["a.dck", "b.dck", "c.dck"]]
    manager.wait()  # Returns once every run has finished, failed ones included.

for simulation in simulations:
    print(simulation.id, simulation.deck_path.name, simulation.succeeded, simulation.status)
    for log in simulation.logs:
        if log.severity == "Fatal":
            print("   ", log.time, log.message)
```

- `SimulationManager(max_concurrent=None, *, database=None, trnrun_path=None,
  executable=..., refresh_interval=0.1, display=True)`. Runs are kept in a
  temporary database, deleted on shutdown. Pass `database="runs.sqlite3"` to
  keep them; a reused file gets the new runs in a new session and keeps the
  old ones.
- The background thread wakes when the daemon announces saved changes, and
  updates the handles and display at most once every `refresh_interval`
  seconds.
- `add(deck_file, config=None, *, label=None)` queues a deck and returns its
  `Simulation` right away; `config` defaults to `SimulationConfig()` and is
  copied, so you can change it between calls.
- `wait(simulation=None, *, timeout=None)` blocks until that run has
  finished, or every run when none is given. A failed run still finishes:
  check `succeeded`. If the daemon crashes or the manager is shut down
  first, it raises that error instead.
- `cancel(simulation)` stops a queued or running run, which then finishes
  as `CANCELLED`. A finished run keeps its outcome.
- `active` lists the unfinished runs; `database_path` is where they are kept,
  and `session_id` the session they belong to.
- `shutdown()`, called when leaving the `with` block, interrupts unfinished
  runs and closes the display. Handles stay readable afterwards.

A `Simulation` has `id` (the daemon's run ID), `deck_path`, and `config`,
then live state read from the database: `state` (`QUEUED`, `RUNNING`,
`FINISHED`), TRNRun's `status`, `progress`, `notices`/`warnings`/`fatals`,
`succeeded`, `error`, `is_finished`, and every log entry in `logs`.
Everything else is in `simulation.info`, a frozen
[`SimulationInfo`](#records). Read `info` once when several fields must
agree.

The display keeps one live line per running simulation and prints each
finished one once above them, in terminals and Jupyter notebooks alike. It
needs Rich, from `pip install trnrun[display]`; without it, `display=True`
raises an `ImportError` that says so.

```text
[1] …\decks\model.dck | Status: DONE       | Logs: N:2 W:1 F:0  | Elapsed: 00:01:12 | ETA: 00:00:00 | [####################]  8,760 /  8,760 (100%)
```

If the daemon crashes, `wait()` raises its error instead of hanging, and so
do later `add()` calls. Call `add()`, `cancel()`, and `shutdown()` from the
thread that created the manager.

### Using it from a GUI

Pass `display=False` and read the handles from your own timer; the manager
still updates them in the background, and reading never blocks:

```python
manager = SimulationManager(display=False)
simulation = manager.add("model.dck", config)

def on_timer():
    progress = simulation.progress
    progress_bar.set(progress.percent if progress else 0)
```

Any object with `update(changed)` and `close()` methods can also be passed as
`display=`; the manager calls `update` from its thread with the simulations
that changed. Applications that need their own polling or database handling
should use `Daemon` directly instead; see
[`examples/example_gui.py`](examples/example_gui.py).

## Database safety

The daemon never deletes runs or logs; a reused database keeps its history.
Keep the database on a local disk; its parent directory must already exist.
Only one daemon may own a database at a time. A database written by an older
trnrund (schema version 2) is refused; start a new file.

## Native executables and packaging

This source package does not build native executables. Deploy both components
using their existing `nimble deploy` tasks, or supply an executable path when
constructing `Daemon`. The existing wheel build hook requires both executables
in `trnrun/bin` and checks that their versions match the Python package version.
