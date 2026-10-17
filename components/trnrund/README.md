# TRNRun daemon

`trnrund` is a Windows daemon that runs TRNRun simulations for one client. It
launches at most `maxConcurrent` simulations at a time and saves their state as
it changes. Clients submit runs over stdin/stdout and read their progress,
results, and logs from a SQLite database the daemon keeps up to date. The
daemon also writes a short notification after each batch of saved changes, so
a client can wait for one instead of polling the database on a timer.

## Build and test

Requires Nim 2.2.10 or later, the
[`db_connector`](https://github.com/nim-lang/db_connector) package, and a
configured C compiler for tests. SQLite itself is the `winsqlite3.dll` built
into Windows 10 and later, so there is no DLL to ship. Release builds use Zig,
which must be on `PATH`. The daemon compiles TRNRun's option parser from
`../trnrun/src`, so build it inside the full repository. Run these commands
from this directory:

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

## Protocol

The client sends one JSON object per stdin line. The daemon answers each one
with exactly one reply line on stdout, in request order, among notification
lines (see [Notifications](#notifications)). A request may carry an
`id`, any JSON value, which its reply repeats first:

```json
{"id":1,"cmd":"ready"}
{"id":2,"cmd":"add","deckFile":"model.dck","trnrunArgs":["--watchTmp:true"],"label":"case A"}
{"id":3,"cmd":"cancel","runId":7}
{"id":4,"cmd":"shutdown","cancelRunning":false}
```

Every reply contains `ok`. A rejected request replies
`{"ok":false,"error":...}`, with its `id` if it had one. A database failure is
never a reply: the daemon exits rather than acknowledge something it could not
save.

| `cmd` | Request fields | Reply fields |
| ----- | -------------- | ------------ |
| `ready` | | `databasePath`, `sessionId`, `revision`, `logId` |
| `add` | `deckFile`, `trnrunArgs`?, `label`? | `runId` |
| `cancel` | `runId` | |
| `shutdown` | `cancelRunning`? | |

### `ready`

Returns the absolute `databasePath` to read and the `sessionId` this daemon
records on its runs. `revision` and `logId` are the largest saved so far; a
client that only wants later changes starts reading after them (see
[Reading the database](#reading-the-database)).

```json
{"id":1,"ok":true,"databasePath":"C:\\runs\\runs.sqlite3","sessionId":3,"revision":120,"logId":45}
```

### `add`

Saves the run as `QUEUED`, starts it at once if a slot is free, and replies
with the `runId` the daemon assigned. Run IDs are integers that are never
reused within a database. The reply does not mean the run has started; read
`state` in the database.

- `trnrunArgs` are TRNRun options, such as `--watchTmp:true`. `add` checks them
  with TRNRun's own parser and rejects the run if TRNRun would refuse one, so a
  typo fails at once instead of when the run starts. The daemon passes the deck
  and `runId` itself, so `trnrunArgs` cannot hold a deck path, `--deckFile`,
  `--runId`, `--help`, or `--version`.
- `label` is an optional text tag saved with the run, for the client's own use.
  It does not need to be unique.

### Notifications

After each batch of changes it saves, the daemon also writes a notification:

```json
{"event":"changed","revision":131}
```

Replies have `ok`; notifications have `event`. A notification means everything
up to `revision` is readable in the database, so a client can block reading
stdout and query the database when one arrives, instead of polling on a timer.
Several changes are announced together, so revisions can skip. Notifications
start after the `revision` that `ready` returns. A client that only wants
replies skips every line without `ok`.

A client that does not read stdout never holds the daemon up: a separate thread
writes it, and notifications the client has not read yet merge into one, which
announces the latest revision. Replies are never dropped, and each write puts the
waiting replies before that one notification. The exceptions are the ends
described under [Shutdown and failures](#shutdown-and-failures).

### `cancel`

Stops one run and replies `{"ok":true}` once the request is recorded:

- A queued run is saved as `FINISHED` and `CANCELLED`, with the error
  `Not started: cancelled by the client`, before the reply.
- A running run has its TRNRun killed; TRNRun's own Job Object then stops
  TrnEXE. The run becomes `FINISHED` and `CANCELLED` shortly after the reply,
  with the error `Interrupted: cancelled by the client`. Its exit code is
  `NULL`, and its freed slot goes to the next queued run.
- A finished run is left unchanged, so a run that finishes just before its
  cancel keeps its real outcome. Only an unknown `runId` is rejected.

If TRNRun reported a terminal status, such as `DONE`, just before it was
killed, that status is kept, but `succeeded` is still false.

### `shutdown`

Replies at once, then:

- Queued runs are saved as `FINISHED` and `CANCELLED`, with the error
  `Not started: the daemon shut down`.
- Running runs are waited for. With `"cancelRunning":true`, they are killed
  instead and saved with the error `Interrupted: the daemon shut down`.
- The daemon exits with code `0` once nothing runs.

While it waits, the daemon still answers every request: `cancel` works,
`shutdown` can be sent again with `cancelRunning`, and `add` is rejected. To
stop waiting at any time, close stdin (see below).

## Reading the database

The daemon saves every change as it happens, so clients only read; they never
need to ask the daemon for updates, and any number of them can read at once.
The changes from each batch the daemon handles become visible together. The
database has three tables. `runs` holds one row per run:

| Column | Type | Meaning |
| ------ | ---- | ------- |
| `run_id` | integer | Assigned by the daemon and returned by `add`; never reused |
| `session_id` | integer | The daemon start that added it; see `sessions` |
| `label` | text | The `label` it was added with, or `NULL` |
| `revision` | integer | Grows with every save; see polling below |
| `state` | text | `QUEUED`, `RUNNING`, or `FINISHED` |
| `trnrun_status`, `trnrun_message` | text | TRNRun's latest `STATUS`, such as `DONE`; not `state` |
| `percent`, `sim_time`, `elapsed_ms`, `eta_ms` | real | TRNRun's latest `PROGRESS` |
| `notices`, `warnings`, `fatals` | integer | Log entries so far, by severity |
| `succeeded` | integer | `1` if it finished with `DONE`, exit code 0, and no error, else `0`; `NULL` until `FINISHED` |
| `exit_code` | integer | TRNRun's exit code |
| `error` | text | Execution error reported by the daemon |
| `submitted_at`, `started_at`, `finished_at` | text | Timestamps, see below |
| `deck_file` | text | Absolute deck path |
| `trnrun_args` | text | The `trnrunArgs` it was added with, as a JSON array |
| `start_time`, `stop_time`, `time_step` | real | TRNRun's `CONFIG`: simulated hours |
| `setting` | text | TRNRun's latest `SETTING` event as JSON, without its `kind` and `timestamp` |

A column TRNRun has not reported yet is `NULL`, as are `exit_code` until TRNRun
exits and `error` when there is none. `setting` holds the options trnrund
knows, one key per TRNRun option; its keys change only with the schema version.

`logs` holds one row per TRNRun `LOG` event:

| Column | Type | Meaning |
| ------ | ---- | ------- |
| `log_id` | integer | Grows with every entry; see polling below |
| `run_id` | integer | The run it belongs to |
| `severity` | text | `Notice`, `Warning`, or `Fatal` |
| `sim_time` | real | Simulated time of the entry |
| `unit_id`, `type_id`, `message_code` | integer | TRNSYS unit, type, and message code; `NULL` if none |
| `message`, `information` | text | TRNSYS text; `NULL` if none |

`sessions` holds one row per daemon start, with its `session_id` and
`started_at`.

`PRAGMA user_version` returns the schema version, currently `3`. It changes
whenever this layout does. A daemon refuses a database of another version, and
there is no migration: point it at a new file. A client can check the version
once after opening.

The timestamps are UTC ISO 8601 text with milliseconds, such as
`2026-10-09T14:03:12.345Z`, which sort chronologically and work with SQLite
date functions. `started_at` is `NULL` until TRNRun starts, and stays `NULL`
for a run that never did; `finished_at` is `NULL` until the run is `FINISHED`.
For example, run times in seconds:

```sql
SELECT run_id, (julianday(finished_at) - julianday(started_at)) * 86400
FROM runs WHERE finished_at IS NOT NULL;
```

### Polling

Every save gets the next `revision`, a counter that only grows, and a run's
logs are saved together with its row. To follow changes, remember the largest
`revision` and `log_id` seen, and ask only for what came after them. Read both
in one transaction to get a consistent view:

```sql
SELECT * FROM runs WHERE revision > ? ORDER BY revision;
SELECT * FROM logs WHERE log_id > ? ORDER BY log_id;
```

Start from 0 to read the whole history, or from the `revision` and `logId`
that `ready` returns to read only what this daemon changes. A client that waits
for notifications runs these queries when one arrives.

Both are indexed, so polling stays fast however many runs the database holds.
So are `state = ?` and `state IN (...)`, which find the few running runs among
thousands queued or finished, and `session_id = ?`; `state != ?` reads every
run instead. For example, a progress bar for the running runs:

```sql
SELECT run_id, percent, eta_ms, notices, warnings, fatals
FROM runs WHERE state = 'RUNNING';
```

A run's logs, in the order TRNRun reported them, are also indexed:

```sql
SELECT * FROM logs WHERE run_id = ? ORDER BY log_id;
```

A run is done once `state` is `FINISHED`, after TRNRun exits. Do not use
`trnrun_status = 'DONE'` or `percent = 1` instead: TRNRun can report them
before it exits, and output may still follow. `FINISHED` includes failed and
cancelled runs; `succeeded` tells them apart, and its logs are then complete.
A run is saved as `FINISHED` once and never changes after.

Open the database read-only, for example with `?mode=ro` in a SQLite URI, and
keep read transactions short. It is in WAL mode, so keep it on a local disk
and leave its `-wal` and `-shm` files beside it; the daemon refuses to start
where WAL is unavailable, such as on a network share.

Runs and logs stay in the database after the daemon exits, and the next daemon
on the same file continues its run numbers in a new session. To start from an
empty history, use a new database file.

Only one daemon at a time can use a database: it holds a `.lock` file beside
it, and a second daemon pointed at the same database exits with code `1`.
Windows deletes the lock file when its daemon exits, even if it crashes.
Readers do not need the lock.

## Examples

[`examples/example_concurrent.ps1`](examples/example_concurrent.ps1) submits a
whole batch at once; [`examples/example_waiting.ps1`](examples/example_waiting.ps1)
waits for each run to leave `QUEUED` before submitting the next, and
[`examples/example_percent.ps1`](examples/example_percent.ps1) also prints
progress. They name runs with `label`, skip notifications, and poll the database
through Python's standard `sqlite3` module, so they need `python` on `PATH`.
Real simulations need TRNSYS.

[`tests/manual_daemon.nim`](tests/manual_daemon.nim) runs 20 copies of a deck
through real TRNSYS; adjust its configuration for your installation.

## Shutdown and failures

- `shutdown` is described [above](#shutdown). It ends with stdout closing and
  exit code `0`.
- Closing stdin exits immediately, also during a `shutdown`, without waiting
  for running simulations. Before exiting, the daemon kills them and saves
  every unfinished run as `FINISHED` and `CANCELLED`, with the error
  `Not started: the client disconnected` or `Interrupted: the client
  disconnected`. The same happens if stdout can no longer be written.
- stdout ends only after the daemon's final changes are saved, so a client
  that reads end of file there can read the database for the outcome. However
  the daemon exits, a client still reading stdout gets everything left to
  write; one that is not reading holds the exit up for at most a second. TRNRun
  children do not inherit the daemon's stdin, stdout, or stderr.
- A kill-on-close Windows Job Object terminates remaining TRNRun descendants
  when the daemon exits.
- If the daemon dies without saving, for example when it is killed, the next
  daemon to open the database finishes its unfinished runs the same way, with
  the reason `its daemon stopped unexpectedly`, and never runs them. Until
  then, those runs keep their last saved state.
- A run whose TRNRun cannot be started finishes at once, from `QUEUED`, with
  the launch error and a daemon `ERROR` status.
- A database failure is fatal: the daemon exits rather than acknowledge a run
  it could not save.
- Startup and fatal diagnostics go to stderr; stdout is reserved for replies
  and notifications. Exit codes are `0` for normal exit, `1` for fatal
  failures, and `2` for invalid options or startup validation errors.
