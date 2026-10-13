# TRNRun for Python

A thin wrapper for the Windows `trnrund` daemon, plus a simulation manager
with a live progress display built on Rich.
Requires Python 3.12 or later and the native `trnrund.exe` and `trnrun.exe`.
Real simulations also require TRNSYS.

Just want to launch a batch and watch it? Skip to the
[simulation manager](#simulation-manager), which needs no polling code.

```python
import time

from trnrun import Daemon, SimulationConfig

config = SimulationConfig(watch_tmp=True)

with Daemon("runs.sqlite3", max_concurrent=2) as daemon:
    daemon.add("1", "model.dck", config)

    while True:
        run = daemon.database.get_run("1")
        if run is not None and run["state"] == "FINISHED":
            print(dict(run))
            break
        daemon.check()  # Raises if trnrund crashed, instead of waiting forever.
        time.sleep(0.2)

    logs = daemon.database.get_logs("1")
```

## API

- `Daemon(database_path="trnrund.sqlite3", *, max_concurrent=None,
  trnrun_path=None, overwrite=False, executable=...)` starts the daemon and
  waits for its `ready` reply before opening the database.
  - `database_path` is created if missing; its directory must exist. An
    existing database keeps its runs, logs, and taken run IDs.
  - `max_concurrent` limits simulations running at once; `None` means
    `max(CPUs - 1, 1)`.
  - `trnrun_path` is the TRNRun runner; `None` means `trnrun.exe` beside
    the daemon executable.
  - `overwrite=True` **permanently deletes** the database's history; see
    [Database safety](#database-safety). It must be an actual `bool`.
  - `executable` defaults to `trnrun/bin/trnrund.exe` inside the package,
    with `trnrun.exe` beside it. To use an existing build, pass
    `executable=r"C:\path\to\trnrund.exe"` and, if needed,
    `trnrun_path=r"C:\path\to\trnrun.exe"`.

  Relative paths resolve from Python's current working directory.
- `add(run_id, deck_file, trnrun_args=())` submits a run. `run_id` must be
  new to the database, even across restarts, so a script rerun on the same
  database needs new IDs (for example with a batch prefix or `uuid`) or
  `overwrite=True`. It accepts a `SimulationConfig` or raw CLI arguments as
  `trnrun_args`.
  A relative `deck_file` resolves from Python's working directory at the time
  of the call, even after `os.chdir()`.
  A config is validated and converted automatically before submission.
  Omitting it sends no overrides and keeps the native runner's defaults.
  The method sends one JSON line to stdin and reads its reply, returning only
  after the run is saved. Rejected requests raise `ValueError`; process and
  protocol failures also raise exceptions; a request to a daemon that has
  exited raises `RuntimeError` with its exit code and its stderr message,
  such as `trnrund exited with code 2: 'maxConcurrent' must be at least 1`.
  The daemon writes to stderr only for startup and fatal errors, so nothing is
  printed to the console, which also keeps notebooks and windowless GUI apps
  free of stray output and console windows.
- `cancel(run_id)` stops one run and returns once the daemon has recorded the
  request. A queued run is already `FINISHED` with `trnrun_status`
  `CANCELLED` on return. A running one has its TRNRun killed, along with
  TRNSYS, and becomes `FINISHED`/`CANCELLED` shortly after; poll the
  database as usual. Its `error` tells which: `Not started: cancelled by the
  client` or `Interrupted: cancelled by the client`. Cancelling a finished run
  changes nothing, so a run that finishes just before keeps its real outcome.
  An unknown `run_id` raises `ValueError`. `shutdown()` blocks until running
  runs finish, so cancel a hanging run before calling it.
- `check()` raises `RuntimeError` if the daemon exited before `shutdown()` or
  `close()`. The database cannot tell a crashed daemon from runs still in
  progress, so call it in every loop that polls `database`.
- `database_path` is the path returned by the daemon, not a guessed filename.
- `database` is a read-only `TrnRunDatabase`, a `sqlite3.Connection` subclass
  with `sqlite3.Row` results and autocommit enabled. All queries go through
  it: use its [query helpers](#standalone-database-access), such as
  `get_run()`, `get_changed_runs()`, and `get_new_logs()`, or normal
  parameterized SQL on `runs` and `logs`. JSON columns remain JSON text.
  Finish cursors promptly to keep reads short.
- `close()` closes the database and stdin, waits for the daemon to exit, and
  **cancels unfinished simulations**. It is safe to call more than once,
  including after the daemon crashed.
  Leaving a `with` block calls `close()`; wait for your runs inside the block.
- `shutdown()` cancels queued runs, waits for running simulations to finish,
  then closes the process pipes. The database and query helpers remain usable
  until `close()` or context-manager exit, so you can read final results and
  cancellations. Later requests are rejected. It can wait indefinitely if a
  simulation hangs; shutdown alone does not release the database reader.

Calls are synchronous and an instance is intended for one thread. There are
no request timeouts, background polling, or result objects. A run finishes
when `state` is `FINISHED`; check `succeeded` to distinguish success from failure.
See the [daemon documentation](../../components/trnrund/README.md) for the
complete database schema, incremental polling queries, and CLI options.

## Standalone database access

`trnrun.database` opens saved results without starting a daemon or requiring
TRNSYS. It uses the same database class as `Daemon`.

```python
from contextlib import closing

from trnrun import TrnRunDatabase

with closing(TrnRunDatabase("runs.sqlite3")) as connection:
    running = connection.get_running_runs()
    print(f"Running: {len(running)}")

    changed = connection.get_changed_runs(after_revision=0)
    for row in changed:
        print(row["run_id"], row["state"], row["succeeded"])

    logs = connection.get_logs("1")
```

- `TrnRunDatabase(path)` opens an existing database with SQLite URI
  `mode=ro`, autocommit enabled, and named `sqlite3.Row` results. It does not
  create a missing database or migrate one. Schema version must be `2`;
  incompatible versions raise `ValueError` after closing the connection.
  Native SQLite errors propagate.
- `connection.get_run(run_id)` returns one current snapshot as a
  `sqlite3.Row`, or `None` if the ID is unknown.
- `connection.get_logs(run_id)` returns its logs ordered by `log_id`, or `[]`
  if there are none, including for an unknown run ID.
- `connection.get_new_logs(after_log_id, run_id=None)` returns only logs
  with a larger `log_id`, of every run or of `run_id`, ordered by `log_id`.
  Use it to follow logs as they arrive: start from `0` to include existing
  logs, then advance your cursor to the last returned `log_id`.
- `connection.count_runs_by_state()` returns a dict such as
  `{"QUEUED": 40, "ACCEPTED": 0, "RUNNING": 2, "FINISHED": 103}`, with every
  state present, for summaries and batch progress.
- `connection.get_latest_revision()` returns the maximum revision, or `0`
  for an empty database. Use it only to initialize monitoring, before seeding
  running rows or submitting runs. Do not use it to advance the cursor each
  poll; advance from the rows returned by `get_changed_runs()` instead.
- `connection.get_running_runs()` returns current `RUNNING` rows, ordered by
  revision, to seed a progress display.
- `connection.get_changed_runs(after_revision)` returns `ACCEPTED`,
  `RUNNING`, and `FINISHED` rows with a newer revision, ordered by revision;
  `QUEUED` rows are skipped. These are latest snapshots, not an event
  history; intermediate states between polls can be skipped. Advance your
  cursor to the largest revision returned, not a separately queried database
  maximum. An empty result is `[]`; JSON text and `NULL` values are returned
  unchanged.

`TrnRunDatabase` is exported from `trnrun` for direct opening, type
annotations, and `help(TrnRunDatabase)`. Its constructor enforces read-only
opening and schema validation. With a daemon, use `daemon.database` instead
of opening another connection.

Use `connection.execute(sql, parameters)` for custom queries. Bind values
with `?` parameters rather than interpolating them into SQL. Connections
retain SQLite's default single-thread restriction; no hidden polling or
revision cursor is added.

A SQLite connection's own `with` block does **not** close it. Use
`contextlib.closing` as above, or call `close()` in `finally`. Standalone
connections belong to the caller, while `daemon.close()` closes its reader.
After shutdown, query helpers still work until that reader is closed.

### Common queries

The helpers cover polling; for anything else, query the `runs` and `logs`
tables directly. The [daemon documentation](../../components/trnrund/README.md#reading-the-database)
describes every column.

```python
# Failed runs and why. Only FINISHED runs have a succeeded value.
failed = connection.execute(
    "SELECT run_id, trnrun_status, error, fatals FROM runs"
    " WHERE state = 'FINISHED' AND NOT succeeded ORDER BY revision",
).fetchall()

# Wall-clock duration in seconds of each run that started and finished.
durations = connection.execute(
    "SELECT run_id, (julianday(finished_at) - julianday(started_at)) * 86400 AS seconds"
    " FROM runs WHERE finished_at IS NOT NULL AND started_at IS NOT NULL",
).fetchall()

# Fatal log entries of one run, with the TRNSYS unit and type that raised them.
fatals = connection.execute(
    "SELECT sim_time, unit_id, type_id, message FROM logs"
    " WHERE run_id = ? AND severity = 'Fatal' ORDER BY log_id",
    ("1",),
).fetchall()

# JSON columns are text; decode them yourself.
import json
args = json.loads(connection.get_run("1")["trnrun_args"])
```

## Simulation configuration

`SimulationConfig()` supplies the current native runner's defaults, with
named, typed fields for editor autocomplete. Use `help(SimulationConfig)` for
all options, their units, CLI mappings, and effects.

```python
from trnrun import SimulationConfig

config = SimulationConfig()
config.trnexe_path = r"C:\TRNSYS18\Exe\TrnEXE64.exe"
config.watch_tmp = True
config.watch_timeout_ms = 3_600_000
config.kill_on_timeout = True
# Reuse config directly with daemon.add("1", "model.dck", config).
```

The default TRNSYS path is `C:\TRNSYS18\Exe\TrnEXE64.exe`; change it for your
installation. Creating a config does not access the executable. Passing it
to `Daemon.add()` calls `to_cli_args()`, which checks the executable exists,
resolves its path from Python's working directory, and returns unquoted
argument strings without changing the config. You can still call
`to_cli_args()` yourself if you need a raw argument list.
Boolean fields require actual `True`/`False`, not strings or integers.
Other option values are parsed by the daemon when submitted.

Common defaults:

| Field | Default | Meaning |
| ----- | ------- | ------- |
| `gui_visibility` | `"hidden"` | No TRNSYS window |
| `watch_log` | `True` | Read TRNSYS log entries |
| `watch_tmp` | `False` | Progress tracking; enabling requires Type3830 |
| `detect_timeout_ms` | `300000` | Five-minute launch-detection timeout |
| `watch_timeout_ms` | `0` | Unlimited runtime monitoring |
| `stall_timeout_ms` | `0` | Stall detection disabled |
| `poll_ms` | `100` | Native runner polling interval in milliseconds |
| `kill_on_timeout`, `kill_on_stall` | `False` | Do not kill on timeout/stall |
| `clean_on_success`, `write_events` | `False` | No cleanup or event-file replacement |

The config emits every field explicitly. Its defaults therefore need to stay
aligned with the bundled runner. `Daemon.add()` still accepts raw CLI argument
lists if you prefer native defaults or need an option not exposed here.
`poll_ms` controls the runner, not the Python display's refresh interval.

## Simulation manager

`trnrun.batch` is for scripts and notebooks that just want to launch
simulations and follow them, without polling code or run IDs.
`SimulationManager` starts the daemon, numbers the runs, keeps one
`Simulation` handle per run up to date from a background thread, and shows
their progress live.

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
  executable=..., poll_interval=0.25, display=True)`. Runs are kept in a
  temporary database, deleted on shutdown. Pass `database="runs.sqlite3"` to
  keep them; reusing that file numbers new runs after the ones already there,
  and never deletes them.
- `add(deck_file, config=None)` queues a deck and returns its `Simulation`
  right away; `config` defaults to `SimulationConfig()` and is copied, so you
  can change it between calls.
- `wait(simulation=None, *, timeout=None)` blocks until that run has
  finished, or every run when none is given. A failed run still finishes:
  check `succeeded`. If the daemon crashes or the manager is shut down
  first, it raises that error instead.
- `cancel(simulation)` stops a queued or running run, which then finishes
  as `CANCELLED`. A finished run keeps its outcome.
- `active` lists the unfinished runs; `database_path` is where they are kept.
- `shutdown()`, called when leaving the `with` block, cancels unfinished runs
  and closes the display. Handles stay readable afterwards.

A `Simulation` has `id`, `deck_path`, and `config`, then live state read from
the database: `state` (`QUEUED`, `ACCEPTED`, `RUNNING`, `FINISHED`), TRNRun's
`status`, `progress` (`percent` from 0 to 1, simulated `time`, `elapsed_ms`,
`eta_ms`), `notices`/`warnings`/`fatals`, `succeeded`, `error`,
`is_finished`, and every log entry in `logs`.

Everything else is in `simulation.info`, a frozen snapshot of the run:
`info.status.message`, `info.exit_code`, `info.submitted_at`/`started_at`/
`finished_at` (UTC), `info.config` (TRNSYS start, stop, step), and
`info.setting` (the settings TRNRun applied). Read `info` once when several
fields must agree.

The display keeps one live line per running simulation and prints each
finished one once above them, in terminals and Jupyter notebooks alike:

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
that changed. Applications that need their own polling, run IDs, or database
handling should use `Daemon` directly instead.

## Database safety

By default, the daemon preserves existing runs and logs, and run IDs must be
unique even across restarts. Keep the database on a local disk; its parent
directory must already exist. Only one daemon may own a database at a time.

**Passing `overwrite=True` permanently deletes existing database history.**
Close all readers before doing so. The wrapper never enables overwrite itself.

## Native executables and packaging

This source package does not build native executables. Deploy both components
using their existing `nimble deploy` tasks, or supply an executable path when
constructing `Daemon`. The existing wheel build hook requires both executables
in `trnrun/bin` and checks that their versions match the Python package version.
