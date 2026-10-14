# trnrund + Python library redesign plan

Scope: items #1–#6 of the design review. Covers `components/trnrund` and
`libraries/python`. **Out of scope:** MATLAB (`libraries/matlab`), Python tests
(none written, none run; `tests/manual_stress_manager.py` is left as is and will
be stale), `trnrunq`, and the `hatch_build.py` error-message bug.

The Nim test suite (`components/trnrund/tests`) is updated to match, and must
pass with `nimble test`.

---

## 1. Daemon-assigned run IDs, sessions, no `--overwrite`

### Schema (`SchemaVersion` 2 → 3)

```sql
CREATE TABLE sessions (
  session_id INTEGER PRIMARY KEY AUTOINCREMENT,
  started_at TEXT NOT NULL);

CREATE TABLE runs (
  run_id INTEGER PRIMARY KEY AUTOINCREMENT,   -- assigned by the daemon, never reused
  session_id INTEGER NOT NULL,                -- daemon start that added it
  label TEXT,                                 -- optional client tag, not unique
  revision INTEGER NOT NULL,
  state TEXT NOT NULL,                        -- QUEUED, RUNNING, FINISHED (see #4)
  ... unchanged progress/outcome/timestamp columns ...
  setting TEXT);                              -- raw TRNRun SETTING JSON (see #3)

CREATE UNIQUE INDEX runs_revision ON runs (revision);
CREATE INDEX runs_state ON runs (state, revision);
CREATE INDEX runs_session ON runs (session_id, revision);
-- logs: run_id becomes INTEGER; otherwise unchanged
```

- Each daemon start inserts one `sessions` row.
- A database of another version is still refused. There is no automatic
  migration: use a new file.

### Protocol

- `add`: `{"cmd":"add","deckFile":..,"trnrunArgs":[..]?,"label":".."?}` →
  `{"ok":true,"runId":17}`. A `runId` sent in the request is ignored.
- `cancel`: `runId` must be an integer.
- `ready` → `{"ok":true,"databasePath":..,"sessionId":..,"revision":..,"logId":..}`.
  `revision` and `logId` are the starting read positions (cursors) for a client
  that only wants changes made after this point.

### Removed

- The `--overwrite` CLI option, `deleteDatabase`, and every doc and test about
  overwriting.
- To start clean, use a new database file.

---

## 2. Push notifications on stdout and request IDs

- **Request IDs:** every request may carry an `id` (any JSON value). The reply
  sends it back unchanged. Replies stay in request order.
- **New `subscribe` command.** After it, the daemon writes
  `{"event":"changed","revision":N}` after each committed batch of changes.
  - Notifications are opt-in. A client that never reads stdout would otherwise
    fill the pipe (about 4 KB by default) and stall the daemon. Clients that
    subscribe must keep reading stdout.
  - Clients tell the two kinds of line apart by whether the line has `ok` or
    `event`.
- **End of stdout means the daemon is gone.** It is reached only after the
  final changes are saved. The daemon makes its own stdin/stdout/stderr handles
  non-inheritable at startup, so TRNRun children cannot hold stdout open after
  the daemon exits.
- **Python:** a background thread reads stdout. It matches replies to requests
  by `id` (replies to requests that already timed out are discarded) and wakes
  anything waiting for changes when a notification or end of stdout arrives.
  This removes the need to call `check()` by hand.

---

## 3. One definition of TRNRun's options

- **trnrund:** remove the typed `SettingEvent`. A `SETTING` event is stored as
  the JSON TRNRun sent, minus `kind` and `timestamp`. A new TRNRun option then
  needs no daemon change and no schema bump.
- **Python `SimulationConfig`:**
  - Every field defaults to `None`, and `to_cli_args()` emits only the fields
    that are set, so TRNRun's defaults live only in trnrun.
  - The type checks on booleans and the existence check on `trnexe_path` still
    apply to fields that are set.
  - `DEFAULT_TRNEXE_PATH` is removed.
- **Python:** `SettingEvent` and `parse_setting` are removed;
  `SimulationInfo.setting` becomes a `dict | None`.
- **Kept as is:** `validate.nim` keeps importing `../../trnrun/src/cli`.
  Both components set nimble `srcDir = "src"`, so their module names (`cli`,
  `events`, `job`, `validate`, `trnrun`) would collide on a shared search path.
  The relative import stays as the single, explicit point of coupling. This is
  a deliberate exception to #3.

---

## 4. Simpler daemon concurrency

- **Launch on the scheduler thread.**
  - `startProcess` runs there (deck, args, `--runId:<int>`).
  - The scheduler owns the `Process` object, and cancelling a run calls
    `process.kill()` from the scheduler thread.
  - The shared `Atomic[bool]` cancel flags, `createShared`/`freeShared`, and
    `mkLaunched` all go away.
  - Launches no longer run concurrently, so one child can no longer inherit
    another child's pipe through handle inheritance.
- **States become `QUEUED → RUNNING → FINISHED`. `ACCEPTED` is removed.**
  - A launch failure goes from `QUEUED` to `FINISHED` with an error and a NULL
    `started_at`.
  - Cancelling is either "Not started" (the run was queued) or "Interrupted"
    (it was running). The race between dispatch and launch no longer exists.
- **Workers only read.**
  - A work item is `(runId, output pipe handle, process handle)`. The process
    handle comes from `OpenProcess(SYNCHRONIZE | QUERY_LIMITED | TERMINATE)` and
    the worker closes it.
  - The worker reads with blocking `ReadFile` until the pipe ends. Lines are
    split on `\n` with a trailing `\r` removed.
  - Then it waits on the process handle, reads the exit code, and posts
    `mkExited`.
  - No `sleep(10)` polling.
  - If reading fails, the worker terminates the process and reports the error.
  - The scheduler closes the `Process` only after applying `mkExited`, so
    workers never use a closed handle.
- **Batched database writes.**
  - The main loop blocks for one inbox message, then takes every message
    already waiting (up to a cap).
  - It applies the whole batch (worker messages and requests) inside one
    database transaction, then writes the replies and at most one `changed`
    notification.
  - `transaction` becomes re-entrant through SQLite savepoints, because
    `recordLog` and `interrupt` nest inside the batch.
- **`Database` becomes a `ref object`** with an in-memory `revision` counter
  (only one daemon can write). The `max(revision)+1` subquery is removed.

### Module changes

| Module | Change |
| --- | --- |
| `messages.nim` | `Work` = `wkRead`/`wkStop`. `Message` = `mkOutput`/`mkExited`/`mkRequest`/`mkClosed` |
| `trnrun.nim` | `launch()` (scheduler thread) + `captureOutput()` (worker thread) |
| `workerpool.nim` | Readers only |
| `scheduler.nim` | Owns the queue and running processes. New `receive`, `apply`, `atomically`, `shutdown(cancelRunning)`, `isDone`, `close`, `abandon` |
| `protocol.nim` | ids, `subscribe`, integer runIds, `label`, `cancelRunning` |
| `trnrund.nim` | Serve loop (batch → transaction → replies → notification). Std handles made non-inheritable. No `--overwrite` |
| `cli.nim` | Drops `overwrite` |
| `database.nim` | Schema 3, sessions, savepoints, no accept/overwrite |
| `events.nim` | `SETTING` stored as `JsonNode` |

---

## 5. Shutdown that always finishes

- `{"cmd":"shutdown","cancelRunning":true?}`:
  - Replies at once.
  - Cancels queued runs.
  - With `cancelRunning`, also kills running runs (saved as "Interrupted: the
    daemon shut down").
  - The daemon exits once nothing is running.
- During shutdown:
  - `cancel` and a repeated `shutdown` (for example, to escalate to
    `cancelRunning`) are accepted.
  - `add` is rejected with an error reply instead of getting no reply.
- Closing stdin during shutdown abandons at once (runs saved as interrupted;
  the Job Object kills TRNRun). This gives a guaranteed way out.
- **Python** `Daemon.shutdown(*, cancel_running=False, timeout=None)`: sends
  shutdown and waits for the daemon to exit. If `timeout` expires, it closes
  stdin, which interrupts the remaining runs. The timeout is enforced on the
  client side, so the daemon needs no timer.
- **Python** requests get a timeout (default 60 s → `TimeoutError`).

---

## 6. Python library structure

New layout of `trnrun/`:

| File | Contents |
| --- | --- |
| `records.py` (new) | Typed records for the core API: `SimulationState` (QUEUED/RUNNING/FINISHED), `SimulationStatus`, `StatusEvent`, `ProgressEvent`, `ConfigEvent`, `LogEvent` (+`log_id`, `run_id`), `SimulationInfo` (+`run_id`, `session_id`, `label`, `revision`, `deck_file`, `trnrun_args`, `setting: dict`, `is_finished`), `Changes(runs, logs)`, `parse_run`, `parse_log` |
| `database.py` | `Database` **wraps** a read-only connection instead of subclassing `sqlite3.Connection` |
| `process.py` | `DaemonProcess` with a stdout reader thread, request ids and timeouts, `wait_for_change`, and end-of-stdout liveness |
| `daemon.py` | `Daemon` (below) |
| `config.py` | `None` defaults (#3) |
| `job.py` | Windows-only; non-Windows branches removed |
| `batch/events.py` | Deleted (moved to `records.py`) |

`Database` methods:
- It is a context manager whose `with` block closes it, and it has `close()`.
- `poll()`: returns the `Changes` since its own cursors and advances them. Runs
  and logs are read in one snapshot transaction.
- `seek_end()`.
- `get_run(run_id)`, `get_logs(run_id)`, `get_runs(session_id=None, state=None)`,
  `count_runs_by_state(session_id=None)`.
- `execute(sql, params)` for custom SQL.
- The old `get_changed_runs`, `get_new_logs`, `get_latest_revision`, and
  `get_running_runs` are removed.

`Daemon` API:
- `Daemon(path, *, max_concurrent, trnrun_path, executable)`. No `overwrite`.
- `add(deck_file, trnrun_args=(), *, label=None) -> int`.
- `cancel(run_id: int)`.
- `poll() -> Changes`: raises only once the daemon has exited unexpectedly
  **and** every saved change has been read.
- `wait(timeout=None) -> Changes`: blocks on notifications, then polls.
- `wait_for_change(after_revision, timeout)`: safe to call from any thread.
- `check()`, `shutdown(...)`, `close()`.
- Attributes: `session_id`, `start_revision`, `start_log_id`.

`batch` changes:
- `SimulationManager`:
  - `Simulation.id` is the daemon's integer `run_id`.
  - The poller waits for `changed` notifications instead of sleeping.
    `poll_interval` is replaced by `refresh_interval`, a minimum time between
    display updates.
  - The poller starts from `daemon.start_revision`/`start_log_id`, so the
    code that scanned for the largest numeric run ID is gone.
  - `add` holds the manager lock across the request and the tracking, so the
    poller cannot see a run before it is tracked.
  - `_daemon_lock` is removed; requests are thread-safe inside
    `DaemonProcess`.
  - `shutdown()` closes the daemon first (end of stdout wakes the poller), then
    joins the poller, deletes the temporary database, and closes the display.
- **Rich becomes optional.**
  - It moves to the `trnrun[display]` extra.
  - `ProgressDisplay` is imported lazily, and `display=True` without Rich
    raises an `ImportError` that says how to install it.
  - The `Display` protocol moves to `manager.py`.

Examples (`example_gui.py`, `example_manager.py`, `example_single.py`, and the
notebook) and `pyproject.toml` are updated to match.

---

## Docs and examples

- `components/trnrund/README.md` is rewritten: CLI, protocol (ids, subscribe,
  replies vs notifications, shutdown), schema 3, polling, and failures.
- `libraries/python/README.md` is rewritten for the new API.
- The PowerShell examples (`example_concurrent`, `example_waiting`,
  `example_percent`) switch to daemon-assigned IDs. They don't subscribe, so
  they keep polling.
- `tests/manual_daemon.nim` is updated to the new protocol.

## Nim tests to update

`test_cli`, `test_events`, `test_database` (the overwrite suite is removed;
sessions and integer IDs added), `test_scheduler`, `test_protocol`,
`test_trnrun` (launch + capture), `test_workerpool`, `test_trnrund` (ids,
subscribe, notifications, end of stdout, shutdown with `cancelRunning`, stdin
closed during shutdown). `test_validate` and `test_job` are unchanged.

## Order of work

1. Nim sources → compile.
2. Nim tests → `nimble test` green.
3. Nim docs and examples.
4. Python package (no tests run; at most static checks with ruff/basedpyright,
   if you want them).
5. Python README and examples.
