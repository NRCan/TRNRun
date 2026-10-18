## Stores every run and its logs in SQLite, the only record of their state.
##
## The daemon numbers runs itself: `run_id` is an `AUTOINCREMENT` key, never
## reused in a database. Each daemon start is one session, and every run
## records the session that added it. Each change to a run updates just the
## columns it affects and gives the row the next revision. Timestamps are UTC
## ISO 8601 text with milliseconds, such as `2026-10-09T14:03:12.345Z`, which
## SQLite date functions accept and which sort chronologically as text.

import std/[json, options, os, oserrors, sequtils, strutils, winlean]
import db_connector/db_sqlite
from db_connector/sqlite3 import PStmt, SQLITE_DONE, SQLITE_ROW, column_count, column_text, step
import ./events

type
  SimulationState* = enum
    ## Run lifecycle, separate from `STATUS`; failed launches and queued cancels skip `RUNNING`.
    ssQueued = "QUEUED" ## Submitted, waiting for a free slot.
    ssRunning = "RUNNING" ## The TRNRun process started.
    ssFinished = "FINISHED" ## Completed or failed; see `succeeded`.

  Database* = ref object
    ## The open database, held exclusively by this daemon until `close`.
    path*: string ## Absolute and normalized.
    connection: DbConn
    lock: Handle ## Exclusive handle on the lock file; 0 once released.
    revision: int ## Revision of the latest save, counted in memory; a failed save can skip one.
    sessionId: int ## This daemon's row in `sessions`.

  SqlArgKind = enum
    sakNull, sakInt, sakFloat, sakText

  SqlArg = object
    ## One value bound to a statement parameter.
    case kind: SqlArgKind
    of sakNull: discard
    of sakInt: intValue: int
    of sakFloat: floatValue: float
    of sakText: textValue: string

const
  SchemaVersion* = 3 ## Bump whenever the tables or the `setting` JSON change what clients read.
  Schema = [
    """CREATE TABLE sessions (
      session_id INTEGER PRIMARY KEY AUTOINCREMENT,
      started_at TEXT NOT NULL)""",
    """CREATE TABLE runs (
      -- Identity and daemon lifecycle
      run_id INTEGER PRIMARY KEY AUTOINCREMENT,
      session_id INTEGER NOT NULL,
      label TEXT,
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
      trnrun_args TEXT NOT NULL,
      start_time REAL,
      stop_time REAL,
      time_step REAL,
      setting TEXT)""",
    # Serves readers polling with `revision > ?`.
    "CREATE UNIQUE INDEX runs_revision ON runs (revision)",
    # Serves `state = ?` and `state IN (...)`, such as the few RUNNING runs among many
    # QUEUED, and the queue in order, since a queued row keeps its submission revision.
    "CREATE INDEX runs_state ON runs (state, revision)",
    # Serves the runs of one session, in the order they changed.
    "CREATE INDEX runs_session ON runs (session_id, revision)",
    """CREATE TABLE logs (
      log_id INTEGER PRIMARY KEY,
      run_id INTEGER NOT NULL,
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
  Unfinished* = {ssQueued, ssRunning} ## States of a run its daemon still tracks.

# SQLite helpers

proc toSqlArg(value: SqlArg): SqlArg =
  ## Passes an already converted argument through.
  value

proc toSqlArg(value: int): SqlArg =
  ## Binds `value` as an INTEGER.
  SqlArg(kind: sakInt, intValue: value)

proc toSqlArg(value: float): SqlArg =
  ## Binds `value` as a REAL.
  SqlArg(kind: sakFloat, floatValue: value)

proc toSqlArg(value: string): SqlArg =
  ## Binds `value` as TEXT.
  SqlArg(kind: sakText, textValue: value)

proc toSqlArg(value: bool): SqlArg =
  ## Binds `value` as 0 or 1.
  toSqlArg(ord(value))

proc toSqlArg(value: enum): SqlArg =
  ## Binds the string value of `value`.
  toSqlArg($value)

proc toSqlArg(value: seq[string]): SqlArg =
  ## Binds `value` as a JSON array.
  toSqlArg($(%value))

proc toSqlArg(value: SettingEvent): SqlArg =
  ## Binds `value` as a JSON object.
  toSqlArg($(%value))

proc toSqlArg[T](value: Option[T]): SqlArg =
  ## Binds the value of `value`, or NULL when it is none.
  if value.isSome: toSqlArg(value.get()) else: SqlArg(kind: sakNull)

proc execute(
    db: Database, query: string, args: varargs[SqlArg, toSqlArg]
): seq[Row] {.discardable.} =
  ## Runs one statement with `args` bound to its parameters; returns its rows.
  # db_sqlite splices quoted args into the SQL, and has no NULL for a none `Option`.
  result = @[]
  let statement = db.connection.prepare(query)
  try:
    for index, arg in args:
      let position = index + 1
      case arg.kind
      of sakNull: statement.bindNull(position)
      of sakInt: statement.bindParam(position, arg.intValue)
      of sakFloat: statement.bindParam(position, arg.floatValue)
      of sakText: statement.bindParam(position, arg.textValue)
    while true:
      case step(statement.PStmt)
      of SQLITE_ROW:
        result.add((0'i32..<column_count(statement.PStmt)).mapIt($column_text(statement.PStmt, it)))
      of SQLITE_DONE: break
      else: dbError(db.connection)
  finally:
    finalize(statement)

proc scalarInt(db: Database, query: string, args: varargs[SqlArg, toSqlArg]): int =
  ## The integer in the first column of the first row `query` returns.
  db.execute(query, args)[0][0].parseInt()

template transaction*(db: Database, body: untyped) =
  ## Runs `body` atomically, rolling back if it raises; nested, it commits with the outermost one.
  execute(db, "SAVEPOINT trnrund")
  try:
    body
    execute(db, "RELEASE trnrund")
  except CatchableError:
    try:
      execute(db, "ROLLBACK TO trnrund")
      execute(db, "RELEASE trnrund")
    except CatchableError:
      discard # Report the original failure, not the cleanup's.
    raise

# Runs

proc savedRevision*(db: Database): int =
  ## Largest revision a run holds: the latest change clients can read.
  db.scalarInt("SELECT coalesce(max(revision), 0) FROM runs")

proc sessionId*(db: Database): int {.inline.} =
  ## This daemon's session, recorded on every run it adds.
  db.sessionId

proc lastLogId*(db: Database): int =
  ## Largest `log_id`, or 0 without logs.
  db.scalarInt("SELECT coalesce(max(log_id), 0) FROM logs")

proc nextRevision(db: Database): int =
  ## Claims the revision for the next save.
  inc db.revision
  db.revision

proc update(db: Database, runId: int, assignments: string, args: varargs[SqlArg, toSqlArg]) =
  ## Applies `assignments` to the row of `runId` and gives it the next revision.
  db.execute("UPDATE runs SET revision = ?, " & assignments & " WHERE run_id = ?",
    @[toSqlArg(db.nextRevision())] & @args & toSqlArg(runId))

proc contains*(db: Database, runId: int): bool =
  ## Whether `runId` was ever saved, by this daemon or an earlier one.
  db.execute("SELECT 1 FROM runs WHERE run_id = ?", runId).len > 0

proc submit*(
    db: Database, deckFile: string, trnrunArgs: seq[string] = @[], label = none(string)
): int =
  ## Saves a new run as `QUEUED` in this session and returns its new `run_id`.
  db.execute("""INSERT INTO runs (session_id, label, revision, state, notices, warnings, fatals,
      submitted_at, deck_file, trnrun_args)
    VALUES (?, ?, ?, ?, 0, 0, 0, """ & Now & ", ?, ?)",
    db.sessionId, label, db.nextRevision(), ssQueued, deckFile, trnrunArgs)
  db.scalarInt("SELECT last_insert_rowid()")

proc start*(db: Database, runId: int) =
  ## Marks `runId` running once its TRNRun process has started.
  db.update(runId, "state = ?, started_at = " & Now, ssRunning)

proc recordSetting(db: Database, runId: int, setting: SettingEvent) =
  ## Replaces the settings of `runId`.
  db.update(runId, "setting = ?", setting)

proc recordStatus(db: Database, runId: int, status: StatusEvent) =
  ## Replaces the latest TRNRun status of `runId`.
  db.update(runId, "trnrun_status = ?, trnrun_message = ?", status.status, status.message)

proc recordConfig(db: Database, runId: int, config: ConfigEvent) =
  ## Replaces the simulation parameters of `runId`.
  db.update(runId, "start_time = ?, stop_time = ?, time_step = ?",
    config.start, config.stop, config.step)

proc recordProgress(db: Database, runId: int, progress: ProgressEvent) =
  ## Replaces the progress of `runId`.
  db.update(runId, "percent = ?, sim_time = ?, elapsed_ms = ?, eta_ms = ?",
    progress.percent, progress.time, progress.elapsedMs, progress.etaMs)

proc recordLog(db: Database, runId: int, log: LogEvent) =
  ## Appends a log entry to `runId` and counts it by severity, atomically.
  let counter =
    case log.severity
    of lsNotice: "notices"
    of lsWarning: "warnings"
    of lsFatal: "fatals"
  db.transaction:
    db.update(runId, counter & " = " & counter & " + 1")
    db.execute("""INSERT INTO logs (run_id, severity, sim_time,
        unit_id, type_id, message_code, message, information)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
      runId, log.severity, log.time,
      log.unitId, log.typeId, log.messageCode, log.message, log.information)

proc record*(db: Database, runId: int, event: SimulationEvent) =
  ## Saves one TRNRun event of `runId`: a `LOG` is appended, any other replaces the previous value.
  case event.kind
  of ekSetting: db.recordSetting(runId, event.setting)
  of ekStatus: db.recordStatus(runId, event.status)
  of ekConfig: db.recordConfig(runId, event.config)
  of ekProgress: db.recordProgress(runId, event.progress)
  of ekLog: db.recordLog(runId, event.log)

proc finish(
    db: Database, runId: int, exitCode: Option[int], error: string, fallback: StatusEvent
) =
  ## Marks `runId` finished, with `fallback` as its status unless TRNRun reported a terminal one.
  # It succeeded only with a `DONE` status from TRNRun, exit code 0, and no execution error.
  db.update(runId, "state = ?, finished_at = " & Now & """,
      exit_code = ?, error = nullif(?, ''),
      trnrun_status = CASE WHEN """ & HasTerminalStatus & """ THEN trnrun_status ELSE ? END,
      trnrun_message = CASE WHEN """ & HasTerminalStatus & """ THEN trnrun_message ELSE ? END,
      succeeded = (trnrun_status IS 'DONE' AND ?)""",
    ssFinished, exitCode, error, fallback.status, fallback.message,
    exitCode == some(0) and error.len == 0)

proc finish*(db: Database, runId: int, exitCode: Option[int], error: string) =
  ## Marks `runId` finished once TRNRun exited or failed to launch; `ERROR` if it reported no end.
  let message = if error.len > 0: error else: "TRNRun exited without a terminal status"
  db.finish(runId, exitCode, error, StatusEvent(status: stError, message: message))

proc cancel*(db: Database, runId: int, started: bool, reason: string) =
  ## Finishes `runId` as CANCELLED, with `reason` after `Interrupted: ` or `Not started: `.
  let outcome = if started: "Interrupted" else: "Not started"
  db.finish(runId, none(int), outcome & ": " & reason,
    StatusEvent(status: stCancelled, message: outcome))

proc interrupt*(db: Database, reason: string, states: set[SimulationState]) =
  ## Cancels every run in one of `states` for `reason`, as runs the daemon stops tracking.
  let states = toSeq(states)
  db.transaction:
    # Reads every row before finishing any, since finishing changes what the query selects.
    for row in db.execute("SELECT run_id, state FROM runs WHERE state IN (" &
        states.mapIt("?").join(", ") & ") ORDER BY revision", states.mapIt(toSqlArg(it))):
      db.cancel(row[0].parseInt(), started = row[1] != $ssQueued, reason)

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
      raise newException(DbError, "Database is in use by another trnrund: " & path)
    raise newException(DbError, "Cannot lock " & lockPath & ": " & osErrorMsg(error))

proc migrate(db: Database) =
  ## Creates the schema in a new database, or refuses one of another version.
  let version = db.scalarInt("PRAGMA user_version")
  if version == 0:
    db.transaction:
      for statement in Schema:
        db.execute(statement)
      db.execute("PRAGMA user_version = " & $SchemaVersion)
  elif version != SchemaVersion:
    raise newException(DbError, "Database " & db.path & " has schema version " &
      $version & "; this trnrund needs " & $SchemaVersion & ". Use a new database file.")

proc close*(db: Database) =
  ## Closes the database, then releases it to other daemons. Idempotent.
  try:
    if db.connection != nil:
      let connection = db.connection
      db.connection = nil
      connection.close()
  finally:
    if db.lock != 0:
      discard closeHandle(db.lock)
      db.lock = 0

proc openDatabase*(path: string): Database =
  ## Opens or creates the database at `path` and starts a new session in it,
  ## holding the database until `close`.
  ##
  ## Runs an earlier daemon left unfinished are finished as interrupted first.
  ## Raises `DbError` when another daemon holds the database, its schema
  ## version differs, or it cannot use WAL mode.
  let path = path.absolutePath().normalizedPath()
  result = Database(path: path, lock: lockDatabase(path))
  try:
    result.connection = db_sqlite.open(result.path, "", "", "")
    result.execute("PRAGMA busy_timeout = 5000")
    # SQLite silently keeps its old mode where WAL is unsupported, such as on a network share.
    if result.execute("PRAGMA journal_mode = WAL")[0][0] != "wal":
      raise newException(DbError, "Cannot use WAL mode; keep the database on a local disk: " & path)
    result.execute("PRAGMA synchronous = NORMAL")
    result.migrate()
    result.revision = result.savedRevision
    result.interrupt("its daemon stopped unexpectedly", Unfinished)
    result.execute("INSERT INTO sessions (started_at) VALUES (" & Now & ")")
    result.sessionId = result.scalarInt("SELECT last_insert_rowid()")
  except CatchableError:
    result.close()
    raise
