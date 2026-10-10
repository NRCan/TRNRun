## SQLite database for simulations, and the only record of their state.
##
## Each change to a run updates just the columns it affects and gives the row
## the next revision. Timestamps are UTC ISO 8601 text with milliseconds, such
## as `2026-10-09T14:03:12.345Z`, which SQLite date functions accept and which
## sort chronologically as text.

import std/[json, options, os, oserrors, sequtils, strutils, winlean]
import db_connector/db_sqlite
from db_connector/sqlite3 import PStmt, SQLITE_DONE, SQLITE_ROW, column_text, step
import ./events

type
  DatabaseError* = DbError

  SimulationState* = enum
    ## Lifecycle of a run, independent of TRNRun `STATUS`.
    ##
    ## `QUEUED → ACCEPTED → RUNNING → FINISHED`. A run whose TRNRun fails to
    ## launch goes from `ACCEPTED` to `FINISHED`; one the daemon stops tracking
    ## first, at shutdown or when it exits, is finished as interrupted from
    ## whatever state it reached.
    ssQueued = "QUEUED" ## Submitted, waiting for an idle worker.
    ssAccepted = "ACCEPTED" ## A pool slot is reserved; worker pickup may be pending.
    ssRunning = "RUNNING" ## The TRNRun process started.
    ssFinished = "FINISHED" ## Completed or failed; see `succeeded`.

  Database* = object
    path*: string ## Absolute and normalized.
    connection: DbConn
    lock: Handle ## Exclusive handle on the lock file.

const
  SchemaVersion* = 1 ## Bump whenever the tables or the `setting` JSON change what clients read.
  Schema = [
    """CREATE TABLE runs (
      -- Identity and daemon lifecycle
      run_id TEXT PRIMARY KEY NOT NULL,
      revision INTEGER NOT NULL,
      state TEXT NOT NULL,
      -- Latest TRNRun status and progress
      trnrun_status TEXT,
      trnrun_message TEXT,
      percent REAL,
      sim_time REAL,
      elapsed_ms REAL,
      eta_ms REAL,
      notices INTEGER NOT NULL,
      warnings INTEGER NOT NULL,
      fatals INTEGER NOT NULL,
      -- Outcome, once FINISHED
      succeeded INTEGER,
      exit_code INTEGER,
      error TEXT,
      -- Timestamps
      submitted_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      -- Set once at submission or launch
      deck_file TEXT NOT NULL,
      start_time REAL,
      stop_time REAL,
      time_step REAL,
      setting TEXT)""",
    # Serves readers polling with `revision > ?` and each save's `max(revision)`.
    "CREATE UNIQUE INDEX runs_revision ON runs (revision)",
    # Serves `state = ?` and `state IN (...)`, such as the few RUNNING runs among many QUEUED.
    "CREATE INDEX runs_state ON runs (state)",
    """CREATE TABLE logs (
      log_id INTEGER PRIMARY KEY,
      run_id TEXT NOT NULL,
      severity TEXT NOT NULL,
      sim_time REAL NOT NULL,
      unit_id INTEGER,
      type_id INTEGER,
      message_code INTEGER,
      message TEXT,
      information TEXT)""",
    "CREATE INDEX logs_run_id ON logs (run_id)",
  ]
  ErrorSharingViolation = 32'i32 # Missing from winlean.
  Now = "strftime('%Y-%m-%dT%H:%M:%fZ')" ## The current time, as every timestamp is stored.
  HasTerminalStatus = "trnrun_status IN ('DONE', 'CANCELLED', 'ERROR', 'TIMEOUT', 'STALLED')"
    ## Whether TRNRun already reported a status that ends a run.
  Unfinished* = {ssQueued, ssAccepted, ssRunning}

# SQLite helpers

proc execute(
    self: Database, query: string, args: varargs[JsonNode, `%`]
): Option[string] {.discardable.} =
  ## Runs one statement with `args` bound by JSON kind; returns its first value, if any.
  # db_sqlite splices quoted args into the SQL and its getValue ignores errors.
  let statement = self.connection.prepare(query)
  try:
    for index, arg in args:
      let position = index + 1
      case arg.kind
      of JNull: statement.bindNull(position)
      of JBool: statement.bindParam(position, ord(arg.getBool()))
      of JInt: statement.bindParam(position, arg.getBiggestInt())
      of JFloat: statement.bindParam(position, arg.getFloat())
      of JString: statement.bindParam(position, arg.getStr())
      of JObject, JArray: statement.bindParam(position, $arg)
    case step(statement.PStmt)
    of SQLITE_ROW: some($column_text(statement.PStmt, 0))
    of SQLITE_DONE: none(string)
    else: dbError(self.connection)
  finally:
    finalize(statement)

template transaction(self: Database, body: untyped) =
  ## Runs `body` atomically, rolling back everything it wrote if it raises.
  self.execute("BEGIN")
  try:
    body
    self.execute("COMMIT")
  except CatchableError:
    discard self.connection.tryExec(sql"ROLLBACK")
    raise

# Runs

proc update(self: Database, runId, assignments: string, args: varargs[JsonNode, `%`]) =
  ## Applies `assignments` to the row of `runId` and gives it the next revision.
  ##
  ## Every right-hand side reads the row as it was before this update.
  self.execute("UPDATE runs SET revision = (SELECT max(revision) + 1 FROM runs), " &
    assignments & " WHERE run_id = ?", @args & %runId)

proc contains*(self: Database, runId: string): bool =
  ## Whether `runId` was ever saved, by this daemon or an earlier one.
  self.execute("SELECT 1 FROM runs WHERE run_id = ?", runId).isSome

proc submit*(self: Database, runId, deckFile: string) =
  ## Saves a new run as `QUEUED`; `runId` must not be in the database yet.
  self.execute("""INSERT INTO runs (run_id, revision, state, notices, warnings, fatals,
      submitted_at, deck_file)
    VALUES (?, (SELECT coalesce(max(revision), 0) + 1 FROM runs), ?, 0, 0, 0, """ &
      Now & ", ?)",
    runId, ssQueued, deckFile)

proc accept*(self: Database, runId: string) =
  ## Marks `runId` handed to a worker.
  self.update(runId, "state = ?", ssAccepted)

proc start*(self: Database, runId: string) =
  ## Marks `runId` running once its TRNRun process started.
  self.update(runId, "state = ?, started_at = " & Now, ssRunning)

proc record*(self: Database, runId: string, event: SimulationEvent) =
  ## Saves one TRNRun event of `runId`.
  ##
  ## `SETTING`, `STATUS`, `CONFIG` and `PROGRESS` replace the previous value;
  ## each `LOG` is appended and counted by severity, atomically.
  case event.kind
  of eventSetting:
    self.update(runId, "setting = ?", event.settingData)
  of eventStatus:
    let status = event.statusData
    self.update(runId, "trnrun_status = ?, trnrun_message = ?", status.status, status.message)
  of eventConfig:
    let config = event.configData
    self.update(runId, "start_time = ?, stop_time = ?, time_step = ?",
      config.start, config.stop, config.step)
  of eventProgress:
    let progress = event.progressData
    self.update(runId, "percent = ?, sim_time = ?, elapsed_ms = ?, eta_ms = ?",
      progress.percent, progress.time, progress.elapsedMs, progress.etaMs)
  of eventLog:
    let log = event.logData
    let counter =
      case log.severity
      of Notice: "notices"
      of Warning: "warnings"
      of Fatal: "fatals"
    self.transaction:
      self.update(runId, counter & " = " & counter & " + 1")
      self.execute("""INSERT INTO logs (run_id, severity, sim_time,
          unit_id, type_id, message_code, message, information)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        runId, log.severity, log.time,
        log.unitId, log.typeId, log.messageCode, log.message, log.information)

proc finish(
    self: Database, runId: string, exitCode: Option[int], error: string, fallback: StatusEvent
) =
  ## Marks `runId` finished, with `fallback` as its status unless TRNRun
  ## already reported a terminal one.
  ##
  ## Success requires a `DONE` status, exit code 0, and no execution error.
  self.update(runId, "state = ?, finished_at = " & Now & """,
      exit_code = ?, error = nullif(?, ''),
      trnrun_status = CASE WHEN """ & HasTerminalStatus & """ THEN trnrun_status ELSE ? END,
      trnrun_message = CASE WHEN """ & HasTerminalStatus & """ THEN trnrun_message ELSE ? END,
      succeeded = (trnrun_status IS 'DONE' AND ?)""",
    ssFinished, exitCode, error, fallback.status, fallback.message,
    exitCode == some(0) and error.len == 0)

proc finish*(self: Database, runId: string, exitCode: Option[int], error: string) =
  ## Marks `runId` finished once TRNRun exited or failed to launch.
  ##
  ## Guarantees a terminal status: when TRNRun did not report one, a
  ## daemon-owned `ERROR` status explains why. Execution errors are kept
  ## independently, even when TRNRun already reported a terminal status.
  let message = if error.len > 0: error else: "TRNRun exited without a terminal status"
  self.finish(runId, exitCode, error, StatusEvent(status: statusError, message: message))

proc interrupt*(self: Database, reason: string, states = Unfinished) =
  ## Finishes every run in `states` that the daemon stops tracking before TRNRun exits.
  ##
  ## A queued run never started; any other may have, and its TRNRun is killed
  ## with the daemon. Either way it is CANCELLED, unless TRNRun already
  ## reported a terminal status, and its error gives `reason`, such as
  ## `Not started: the daemon shut down`.
  let selected = toSeq(states).mapIt("'" & $it & "'").join(", ")
  self.transaction:
    for row in self.connection.getAllRows(sql("SELECT run_id, state FROM runs WHERE state IN (" &
        selected & ") ORDER BY revision")):
      let outcome = if row[1] == $ssQueued: "Not started" else: "Interrupted"
      self.finish(row[0], none(int), outcome & ": " & reason,
        StatusEvent(status: statusCancelled, message: outcome))

# Opening and closing

proc lockDatabase(path: string): Handle =
  ## Opens `<path>.lock` exclusively, so no other daemon can open `path`.
  let lockPath = path & ".lock"
  result = createFileW(
    newWideCString(lockPath),
    GENERIC_READ or GENERIC_WRITE,
    0, # No sharing: any other open fails while this handle lives.
    nil,
    OPEN_ALWAYS,
    FILE_ATTRIBUTE_NORMAL or FILE_FLAG_DELETE_ON_CLOSE, # Gone with the handle, even on a crash.
    0,
  )
  if result == INVALID_HANDLE_VALUE:
    let error = osLastError()
    if error.int32 == ErrorSharingViolation:
      raise newException(DatabaseError, "Database is in use by another trnrund: " & path)
    raise newException(DatabaseError, "Cannot lock " & lockPath & ": " & osErrorMsg(error))

proc migrate(self: Database) =
  ## Creates the schema in a new database, or refuses one of another version.
  let version = self.execute("PRAGMA user_version").get().parseInt()
  if version == 0:
    self.transaction:
      for statement in Schema:
        self.execute(statement)
      self.execute("PRAGMA user_version = " & $SchemaVersion)
  elif version != SchemaVersion:
    raise newException(DatabaseError, "Database " & self.path & " has schema version " &
      $version & "; this trnrund needs " & $SchemaVersion)

proc close*(self: Database) =
  ## Closes the database, then releases it to other daemons.
  try:
    if self.connection != nil:
      self.connection.close()
  finally:
    discard closeHandle(self.lock)

proc openDatabase*(path: string): Database =
  ## Opens or creates the database at `path`, holding it until `close`; raises `DatabaseError`.
  let path = path.absolutePath().normalizedPath()
  result = Database(path: path, lock: lockDatabase(path))
  try:
    result.connection = db_sqlite.open(result.path, "", "", "")
    result.execute("PRAGMA busy_timeout = 5000")
    result.execute("PRAGMA journal_mode = WAL")
    result.execute("PRAGMA synchronous = NORMAL")
    result.migrate()
    result.interrupt("its daemon stopped unexpectedly") # Runs an earlier daemon left unfinished.
  except CatchableError:
    result.close()
    raise
