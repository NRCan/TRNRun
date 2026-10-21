# TRNRun Daemon

`trnrund.exe` is a Windows daemon that runs TRNSYS simulations through
[TRNRun Runner](https://github.com/NRCan/TRNRun/tree/main/components/trnrun)
on behalf of one client application. It reads requests as JSON Lines from
stdin, runs them on a bounded pool of `trnrun.exe` processes, and records
their progress, results, and logs in a SQLite database.

## Table of Contents

- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Settings](#settings)
- [Request protocol](#request-protocol)
- [Notifications](#notifications)
- [Reading the database](#reading-the-database)
- [Shutdown and failures](#shutdown-and-failures)
- [Exit codes](#exit-codes)
- [Examples](#examples)
- [See also](#see-also)

## Requirements

### Runtime

- Windows 10 or later, x64
- [`trnrun.exe`](https://github.com/NRCan/TRNRun/tree/main/components/trnrun)
  executable
- TRNSYS 17 or 18 for actual simulation runs

### Development

- [Nim](https://nim-lang.org/install.html) 2.2.12 or newer
- [Zig](https://ziglang.org/download/) 0.17.0 as the Windows C compiler and
  resource compiler
- [just](https://github.com/casey/just) for repository-root recipes

## Installation

Download and extract `trnrund-v<version>-win_amd64.zip` from
[GitHub Releases](https://github.com/NRCan/TRNRun/releases). The daemon does
not bundle the runner; install `trnrun.exe` beside `trnrund.exe` or provide its
path with `--trnrun`.

Or build from source:

```powershell
Set-Location components/trnrund
nimble install -d
nimble bin
```

The executable is written to `components/trnrund/build/trnrund.exe` relative
to the repository root.

## Quick start

Start the daemon with a runner, a concurrency limit, and a database:

```powershell
trnrund --trnrun:"C:\bin\trnrun.exe" `
    --maxConcurrent:2 `
    --database:"C:\runs\runs.sqlite3"
```

Then write one request per line to its stdin:

```json
{"id":1,"cmd":"ready"}
{"id":2,"cmd":"add","deckFile":"C:\\models\\building-a.dck","trnrunArgs":["--watchTmp:true"]}
{"id":3,"cmd":"shutdown"}
```

For option and version information:

```powershell
trnrund --help
trnrund --version
```

## Settings

Options accept either `--name:value` or `--name=value`. Relative TRNRun, deck,
and database paths resolve from the daemon's working directory.

- _`--trnrun`_ (`path`, default: `trnrun.exe` beside `trnrund.exe`)

  TRNRun executable used for every run. It must be an existing file.

- _`--maxConcurrent`_ (`integer`, default: `max(logical processors - 1, 1)`)

  Maximum number of simulations running at once. The value must be at least
  `1`.

- _`--database`_ (`path`, default: `trnrund.sqlite3`)

  SQLite database the daemon writes and clients read. The database's directory
  must exist.

## Request protocol

The client writes one JSON request per line to stdin. The daemon writes one
reply per request to stdout, in the same order. stdout also carries
[notifications](#notifications); replies have an `ok` field, notifications
have an `event` field. Startup and fatal errors go to stderr.

A request may include an `id` (any JSON value). The reply echoes it as its
first field, so a client that stopped waiting can still match a late reply to
its request.

Each command below shows a request line and its reply line.

The `cmd` field picks the command:

- [`ready`](#ready): get the database to read.
- [`add`](#add): queue a simulation.
- [`cancel`](#cancel): stop one run.
- [`shutdown`](#shutdown): stop the daemon.

### `ready`

Reports the database to read and how far its history goes, so a client knows
where to start reading.

```jsonc
// stdin
{"id":1,"cmd":"ready"}
// stdout
{"id":1,"ok":true,"databasePath":"C:\\runs\\runs.sqlite3","sessionId":3,"revision":120,"logId":45}
```

- **stdin**: no fields besides `cmd`.
- **stdout**:
  - `databasePath`: absolute path of the database to read.
  - `sessionId`: the session this daemon records on its runs.
  - `revision`, `logId`: the largest saved so far; a client that only wants
    later changes starts reading after them (see [Polling](#polling)).

### `add`

Saves a simulation as `QUEUED`, starts it at once if a slot is free, and
replies with its `runId`. The reply does not mean the run has started; read
`state` in the database.

```jsonc
// stdin
{"id":2,"cmd":"add","deckFile":"model.dck","trnrunArgs":["--watchTmp:true"],"label":"case A"}
// stdout
{"id":2,"ok":true,"runId":7}
```

- **stdin**:
  - `deckFile`: an existing `.dck` or `.trd` file; extensions are
    case-insensitive.
  - `trnrunArgs` (optional): TRNRun options, such as `--watchTmp:true`. `add`
    checks them with TRNRun's own parser and rejects the run if TRNRun would
    refuse one, so a typo fails at once instead of when the run starts. The
    daemon passes the deck and `runId` itself, so `trnrunArgs` cannot hold a
    deck path, `--deckFile`, `--runId`, `--help`, or `--version`.
  - `label` (optional): a text tag saved with the run, for the client's own
    use. It does not need to be unique.
- **stdout**:
  - `runId`: the ID the daemon assigned, an integer never reused within a
    database.

### `cancel`

Stops one queued or running run.

```jsonc
// stdin
{"id":3,"cmd":"cancel","runId":7}
// stdout
{"id":3,"ok":true}
```

- **stdin**:
  - `runId`: the run to stop. Only an unknown `runId` is rejected.
- **stdout**: no fields besides `ok`, once the request is recorded.

### `shutdown`

Stops accepting runs and exits the daemon once nothing runs.

```jsonc
// stdin
{"id":4,"cmd":"shutdown","cancelRunning":false}
// stdout
{"id":4,"ok":true}
```

- **stdin**:
  - `cancelRunning` (optional, default `false`): kill running runs instead of
    waiting for them.
- **stdout**: no fields besides `ok`, at once.

### Errors

A rejected request, such as malformed JSON, an unknown `cmd`, or invalid
fields, gets `ok: false` and an `error` message, with its `id` if it had one:

```jsonc
// stdin
{"id":5,"cmd":"cancel","runId":99}
// stdout
{"id":5,"ok":false,"error":"Unknown runId: 99"}
```

A database failure is never a reply: the daemon exits rather than acknowledge
something it could not save.

## Notifications

After each batch of changes it saves, the daemon also writes a notification:

```json
{"event":"changed","revision":131}
```

Everything up to `revision` is then readable in the database, so a client can
wait for a notification instead of polling on a timer. A
client that only wants replies skips every line without `ok`.

## Reading the database

The daemon saves every change as it happens, so clients only read; they never
need to ask the daemon for updates, and any number of them can read at once.
The changes from each batch the daemon handles become visible together. The
database has three tables.

### `runs` table

`runs` holds one row per run:

| Column | Type | Meaning |
| ------ | ---- | ------- |
| `run_id` | integer | Assigned by the daemon and returned by `add`; never reused |
| `session_id` | integer | The daemon start that added it; see `sessions` |
| `label` | text | The `label` it was added with, or `NULL` |
| `revision` | integer | Grows with every save; see [Polling](#polling) |
| `state` | text | `QUEUED`, `RUNNING`, or `FINISHED` |
| `trnrun_status`, `trnrun_message` | text | TRNRun's latest `STATUS`; not `state`. `PENDING`, `LAUNCHING`, or `RUNNING` while it runs, then `DONE`, `CANCELLED`, `ERROR`, `TIMEOUT`, or `STALLED` |
| `percent`, `sim_time`, `elapsed_ms`, `eta_ms` | real | TRNRun's latest `PROGRESS` |
| `notices`, `warnings`, `fatals` | integer | Log entries so far, by severity |
| `succeeded` | integer | `1` if it finished with `DONE`, exit code 0, and no error, else `0`; `NULL` until `FINISHED` |
| `exit_code` | integer | TRNRun's exit code |
| `error` | text | Execution error reported by the daemon |
| `submitted_at`, `started_at`, `finished_at` | text | Timestamps, see [Timestamps](#timestamps) |
| `deck_file` | text | Absolute deck path |
| `trnrun_args` | text | The `trnrunArgs` it was added with, as a JSON array |
| `start_time`, `stop_time`, `time_step` | real | TRNRun's `CONFIG`: simulated hours |
| `setting` | text | TRNRun's latest `SETTING` event as JSON, without its `kind` and `timestamp` |

A column TRNRun has not reported yet is `NULL`, as are `exit_code` until TRNRun
exits and `error` when there is none. `setting` holds the options trnrund
knows, one key per TRNRun option; its keys change only with the schema version.

### `logs` table

`logs` holds one row per TRNRun `LOG` event:

| Column | Type | Meaning |
| ------ | ---- | ------- |
| `log_id` | integer | Grows with every entry; see [Polling](#polling) |
| `run_id` | integer | The run it belongs to |
| `severity` | text | `Notice`, `Warning`, or `Fatal` |
| `sim_time` | real | Simulated time of the entry |
| `unit_id`, `type_id`, `message_code` | integer | TRNSYS unit, type, and message code; `NULL` if none |
| `message`, `information` | text | TRNSYS text; `NULL` if none |

### `sessions` table

`sessions` holds one row per daemon start, with its `session_id` and
`started_at`.

### Schema version

`PRAGMA user_version` returns the schema version, currently `3`. It changes
whenever this layout does, so the tables, columns, and values documented here
are the interface clients can rely on. A daemon refuses a database of another
version, and there is no migration: point it at a new file. A client can check
the version once after opening.

### Timestamps

The timestamps are UTC ISO 8601 text with milliseconds, such as
`2026-10-09T14:03:12.345Z`, which sort chronologically and work with SQLite
date functions. `started_at` is `NULL` until TRNRun starts, and stays `NULL`
for a run that never did; `finished_at` is `NULL` until the run is `FINISHED`.
For example, run times in seconds:

```sql
SELECT run_id, ROUND((julianday(finished_at) - julianday(started_at)) * 86400, 3)
FROM runs WHERE finished_at IS NOT NULL;
```

### Polling

Every save gets the next `revision`, a counter that only grows but can skip
numbers, so always compare with `>`. A run's logs are saved together with its
row, and each one gives the run a new `revision`, so a new revision also
announces new logs. To follow changes, remember the largest `revision` and
`log_id` seen, and ask only for what came after them. Read both in one
transaction to get a consistent view:

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

### Completion

A run is done once `state` is `FINISHED`, after TRNRun exits. Do not use
`trnrun_status = 'DONE'` or `percent = 1` instead: TRNRun can report them
before it exits, and output may still follow. `FINISHED` includes failed and
cancelled runs; `succeeded` tells them apart, and its logs are then complete.
A run is saved as `FINISHED` once and never changes after.

### Database files

Open the database read-only, for example with `?mode=ro` in a SQLite URI, and
keep read transactions short. It is in WAL mode, so keep it on a local disk
and leave its `-wal` and `-shm` files beside it; the daemon refuses to start
where WAL is unavailable, such as on a network share.

Runs and logs stay in the database after the daemon exits, and the next daemon
on the same file continues its run numbers, revisions, and log IDs in a new
session, so the positions a client remembered stay valid. To start from an
empty history, use a new database file.

Only one daemon at a time can use a database: it holds a `.lock` file beside
it, and a second daemon pointed at the same database exits with code `1`.
Windows deletes the lock file when its daemon exits, even if it crashes.
Readers do not need the lock.

## Shutdown and failures

- [`cancel`](#cancel) saves a queued run as `FINISHED` and `CANCELLED`, with
  the error `Not started: cancelled by the client`, before its reply. A running
  run has its TRNRun killed, and TRNRun's own Job Object then stops TrnEXE; the
  run becomes `FINISHED` and `CANCELLED` shortly after the reply, with the
  error `Interrupted: cancelled by the client`, a `NULL` exit code, and its
  slot freed for the next queued run. A finished run is left unchanged, so a
  run that finishes just before its cancel keeps its real outcome. If TRNRun
  reported a terminal status, such as `DONE`, just before it was killed, that
  status is kept, but `succeeded` is still false.
- [`shutdown`](#shutdown) saves queued runs as `FINISHED` and `CANCELLED`,
  with the error `Not started: the daemon shut down`. Running runs are waited
  for, or with `cancelRunning` killed and saved with the error
  `Interrupted: the daemon shut down`. While it waits, the daemon still answers
  every request: `cancel` works, `shutdown` can be sent again with
  `cancelRunning`, and `add` is rejected. It ends with stdout closing and exit
  code `0`.
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

## Exit codes

| Exit code | Meaning |
| --- | --- |
| `0` | Normal exit after `shutdown` or closed stdin. Help and version also return `0`. Individual runs may still have failed. |
| `1` | Fatal failure, such as a database error or a database locked by another daemon. |
| `2` | Invalid option or startup validation error. |

Run outcomes do not become the daemon's exit code. Read `succeeded` and
`exit_code` in the `runs` table instead.

## Examples

PowerShell examples are available in
[`examples`](https://github.com/NRCan/TRNRun/tree/main/components/trnrund/examples).
They expect `build/trnrund.exe` and `../trnrun/build/trnrun.exe` to exist, and
poll the database through Python's standard `sqlite3` module, so they need
`python` on `PATH`. Real simulations need TRNSYS.

- [`example_concurrent.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_concurrent.ps1)
  submits the full batch immediately.
- [`example_waiting.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_waiting.ps1)
  waits for each run to leave `QUEUED` before submitting the next.
- [`example_percent.ps1`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/examples/example_percent.ps1)
  does the same and also prints progress.

The scripts name runs with `label` and skip notifications.

[`tests/manual_daemon.nim`](https://github.com/NRCan/TRNRun/blob/main/components/trnrund/tests/manual_daemon.nim)
runs 20 copies of a deck through real TRNSYS; adjust its configuration for your
installation.

## See also

- [TRNRun Runner](https://github.com/NRCan/TRNRun/tree/main/components/trnrun):
  runs a single TRNSYS simulation and reports its lifecycle as a JSON Lines
  event stream.
- [TRNRun Queue](https://github.com/NRCan/TRNRun/tree/main/components/trnrunq):
  runs batches of simulations through a bounded pool of runners and merges
  their events into a single stream.
