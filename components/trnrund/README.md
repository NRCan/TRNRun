# TRNRun daemon

`trnrund` is a Windows daemon that runs TRNRun simulations for one client. A
fixed worker pool executes simulations while the scheduler limits concurrency
and saves their state. Clients submit runs over stdin/stdout and read their
progress, results, and logs from a SQLite database the daemon keeps up to date.

## Build and test

Requires Nim 2.2.10 or later, the
[`db_connector`](https://github.com/nim-lang/db_connector) package, and a
configured C compiler for tests. SQLite itself is the `winsqlite3.dll` built
into Windows 10 and later, so there is no DLL to ship. Release builds use Zig,
which must be on `PATH`. Run these commands from this directory:

```sh
nimble install -d
nimble test
nimble bin
```

`nimble test` builds a fake TRNRun child, the daemon, and all test executables,
then runs every suite. Tests do not require TRNSYS. `nimble bin` builds the
release executable at `build/trnrund.exe`.

`nimble dist` assembles a distributable package; `nimble deploy` also copies it
to the repository's MATLAB and Python manager directories.

## Usage

```sh
build/trnrund.exe --trnrun:C:/path/to/trnrun.exe --maxConcurrent:2 --database:C:/runs/runs.sqlite3
```

By default, the daemon uses `trnrun.exe` beside its executable, runs at most
`max(CPUs - 1, 1)` simulations concurrently, and keeps its database in
`trnrund.sqlite3`. Relative TRNRun, deck, and database paths resolve from the
daemon's working directory; the database's directory must exist. Decks must be
existing `.dck` or `.trd` files; extensions are case-insensitive.

The client sends one JSON object per stdin line and receives one JSON reply
per stdout line, in request order:

```json
{"cmd":"ready"}
{"cmd":"add","runId":"1","deckFile":"model.dck","trnrunArgs":["--watchTmp:true"]}
{"cmd":"shutdown"}
```

Each reply contains `ok`. Failed requests contain `error`. `ready` also returns
the absolute `databasePath` to read:

```json
{"ok":true,"databasePath":"C:\\runs\\runs.sqlite3"}
```

`add` replies at once with the run's `state`: `QUEUED`, or `ACCEPTED` if a
worker took the run immediately. To follow a run or wait for it to finish,
poll the database; see below.

See [`src/protocol.nim`](src/protocol.nim) for request fields and defaults.

## Reading the database

The daemon saves every change as it happens, so clients only read; they never
need to ask the daemon for updates, and any number of them can read at once.
The database has two tables. `runs` holds one row per run:

| Column | Type | Meaning |
| ------ | ---- | ------- |
| `run_id` | text | The `runId` it was added with |
| `revision` | integer | Grows with every save; see polling below |
| `state` | text | `QUEUED`, `ACCEPTED`, `RUNNING`, or `FINISHED` |
| `trnrun_status`, `trnrun_message` | text | TRNRun's latest `STATUS`, such as `DONE`; not `state` |
| `percent`, `sim_time`, `elapsed_ms`, `eta_ms` | real | TRNRun's latest `PROGRESS` |
| `notices`, `warnings`, `fatals` | integer | Log entries so far, by severity |
| `succeeded` | integer | `1` if it finished with `DONE`, exit code 0, and no error, else `0`; `NULL` until `FINISHED` |
| `exit_code` | integer | TRNRun's exit code |
| `error` | text | Execution error reported by the daemon |
| `submitted_at`, `started_at`, `finished_at` | text | Timestamps, see below |
| `deck_file` | text | Absolute deck path |
| `start_time`, `stop_time`, `time_step` | real | TRNRun's `CONFIG`: simulated hours |
| `setting` | text | TRNRun's `SETTING` event as JSON, without its `kind` |

A column TRNRun has not reported yet is `NULL`, as are `exit_code` until TRNRun
exits and `error` when there is none. `logs` holds one row per TRNRun `LOG`
event:

| Column | Type | Meaning |
| ------ | ---- | ------- |
| `log_id` | integer | Grows with every entry; see polling below |
| `run_id` | text | The run it belongs to |
| `severity` | text | `Notice`, `Warning`, or `Fatal` |
| `sim_time` | real | Simulated time of the entry |
| `unit_id`, `type_id`, `message_code` | integer | TRNSYS unit, type, and message code; `NULL` if none |
| `message`, `information` | text | TRNSYS text; `NULL` if none |

`PRAGMA user_version` returns the schema version, currently `1`. It changes
whenever this layout does, and a daemon refuses a database of another version,
so a client can check it once after opening.

The timestamps are UTC ISO 8601 text with milliseconds, such as
`2026-10-09T14:03:12.345Z`, which sort chronologically and work with SQLite
date functions. `started_at` is `NULL` until TRNRun starts, and stays `NULL`
for a run that never did; `finished_at` is `NULL` until the run is `FINISHED`.
For example, run times in seconds:

```sql
SELECT run_id, (julianday(finished_at) - julianday(started_at)) * 86400
FROM runs WHERE finished_at IS NOT NULL;
```

Every save gets the next `revision`, a counter that only grows, and a run's
logs are saved together with its row. To poll, remember the largest
`revision` and `log_id` seen, and ask only for what came after them:

```sql
SELECT * FROM runs WHERE revision > ? ORDER BY revision;
SELECT * FROM logs WHERE log_id > ? ORDER BY log_id;
```

Both are indexed, so polling stays fast however many runs the database holds.
So are `state = ?` and `state IN (...)`, which find the few running runs among
thousands queued or finished; `state != ?` reads every run instead. For
example, a progress bar for the running runs:

```sql
SELECT run_id, percent, eta_ms, notices, warnings, fatals
FROM runs WHERE state = 'RUNNING';
```

A run's logs, in the order TRNRun reported them, are also indexed:

```sql
SELECT * FROM logs WHERE run_id = ? ORDER BY log_id;
```

A run is done once `state` is `FINISHED`, after TRNRun exits. Do not use
`trnrun_status = 'DONE'` or `percent = 100` instead: TRNRun can report them
before it exits, and output may still follow. `FINISHED` includes failed and
cancelled runs; `succeeded` tells them apart, and its logs are then complete.

A run is saved as `FINISHED` once and never changes after, so a client can
report each finished run exactly once by keeping the largest `revision` it
has seen:

```sql
SELECT run_id, succeeded, trnrun_status, warnings, fatals, revision
FROM runs WHERE revision > ? AND state = 'FINISHED' ORDER BY revision;
```

Start from `SELECT coalesce(max(revision), 0) FROM runs` to skip the runs that
finished before the client started.

Open the database read-only, for example with `?mode=ro` in a SQLite URI, and
keep read transactions short. It is in WAL mode, so keep it on a local disk
and leave its `-wal` and `-shm` files beside it.

Runs stay in the database after the daemon exits, and a `runId` can never be
reused in the same database, even by a later daemon. Use a new database, or
unique run IDs, for each batch.

Only one daemon at a time can use a database: it holds a `.lock` file beside
it, and a second daemon pointed at the same database exits with code `1`.
Windows deletes the lock file when its daemon exits, even if it crashes.
Readers do not need the lock.

## Examples

[`examples/example_concurrent.ps1`](examples/example_concurrent.ps1) submits a
whole batch at once; [`examples/example_waiting.ps1`](examples/example_waiting.ps1)
waits for each run to leave `QUEUED` before submitting the next. Both read the
database through Python's standard `sqlite3` module, so they need `python` on
`PATH`, and real simulations need TRNSYS.

[`tests/manual_daemon.nim`](tests/manual_daemon.nim) runs 20 copies of a deck
through real TRNSYS; adjust its configuration for your installation.

## Shutdown and failures

- The `shutdown` command acknowledges immediately, cancels runs not yet
  dispatched, waits for submitted runs to finish, and joins the workers.
- Closing stdin exits immediately, without waiting for running simulations.
  Before exiting, the daemon saves every unfinished run as `FINISHED` and
  `CANCELLED`, with the error `Not started: the client disconnected` or
  `Interrupted: the client disconnected`.
- A kill-on-close Windows Job Object terminates remaining TRNRun descendants
  when the daemon exits.
- If the daemon dies without saving, for example when it is killed, the next
  daemon to open the database finishes its unfinished runs the same way, with
  the reason `its daemon stopped unexpectedly`. Until then, those runs keep
  their last saved state.
- A database failure is fatal: the daemon exits rather than acknowledge a run
  it could not save.
- Startup and fatal diagnostics go to stderr; stdout is reserved for replies
  while serving requests. Exit codes are `0` for normal exit, `1` for fatal
  failures, and `2` for invalid options or startup validation errors.

Running simulations cannot be cancelled through the protocol. Graceful
shutdown can therefore wait indefinitely for TRNRun. Channels intentionally
remain open because of the documented Nim 2.2 ORC channel-close workaround.
