## SQLite database for simulations, and the only record of their state.
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
    ## Lifecycle of a run, independent of TRNRun `STATUS`.
    ##
    ## `QUEUED → RUNNING → FINISHED`. A run whose TRNRun fails to launch, or
    ## that is cancelled while queued, goes from `QUEUED` to `FINISHED`.
    ssQueued = "QUEUED" ## Submitted, waiting for a free slot.
    ssRunning = "RUNNING" ## The TRNRun process started.
    ssFinished = "FINISHED" ## Completed or failed; see `succeeded`.

  Database* = ref object
    ## The open database, held exclusively by this daemon until `close`.
    ##
    ## A `ref` so the revision counter it keeps in memory is shared by every
    ## holder; only this daemon writes, so the counter is the database's.
    path*: string ## Absolute and normalized.
    connection: DbConn
    lock: Handle ## Exclusive handle on the lock file; 0 once released.
    revision: int ## Revision of the latest save.
    sessionId: int ## This daemon's row in `sessions`.

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
  Unfinished* = {ssQueued, ssRunning}

# SQLite helpers

proc execute(
    self: Database, query: string, args: varargs[JsonNode, `%`]
): seq[Row] {.discardable.} =
  ## Runs one statement with `args` bound by JSON kind; returns its rows.
  # db_sqlite splices quoted args into the SQL, and has no NULL for a none `Option`.
  result = @[]
  let statement = self.connection.prepare(query)
  try:
    for index, arg in args:
      let position = index + 1
      case arg.kind
      of JNull: statement.bindNull(position)
      of JBool: statement.bindParam(position, ord(arg.getBool()))
      of JInt: statement.bindParam(position, arg.getInt())
      of JFloat: statement.bindParam(position, arg.getFloat())
      of JString: statement.bindParam(position, arg.getStr())
      of JObject, JArray: statement.bindParam(position, $arg)
    while true:
      case step(statement.PStmt)
      of SQLITE_ROW:
        result.add((0'i32 ..< column_count(statement.PStmt)).mapIt($column_text(statement.PStmt, it)))
      of SQLITE_DONE: break
      else: dbError(self.connection)
  finally:
    finalize(statement)

template transaction*(self: Database, body: untyped) =
  ## Runs `body` atomically, rolling back everything it wrote if it raises.
  ##
  ## Nests: an inner transaction commits with the outermost one. Readers see
  ## the writes of `body` only once the outermost one commits.
  execute(self, "SAVEPOINT trnrund")
  try:
    body
    execute(self, "RELEASE trnrund")
  except CatchableError:
    try:
      execute(self, "ROLLBACK TO trnrund")
      execute(self, "RELEASE trnrund")
    except CatchableError:
      discard # Report the original failure, not the cleanup's.
    raise

# Runs

proc revision*(self: Database): int =
  ## Revision of the latest save, counted in memory; a failed save can skip one.
  self.revision

proc savedRevision*(self: Database): int =
  ## Largest revision a run holds, the one readers can reach. What clients are told.
  self.execute("SELECT coalesce(max(revision), 0) FROM runs")[0][0].parseInt()

proc sessionId*(self: Database): int =
  ## This daemon's session, recorded on every run it adds.
  self.sessionId

proc lastLogId*(self: Database): int =
  ## Largest `log_id`, or 0 without logs.
  self.execute("SELECT coalesce(max(log_id), 0) FROM logs")[0][0].parseInt()

proc nextRevision(self: Database): int =
  inc self.revision
  self.revision

proc update(self: Database, runId: int, assignments: string, args: varargs[JsonNode, `%`]) =
  ## Applies `assignments` to the row of `runId` and gives it the next revision.
  ##
  ## Every right-hand side reads the row as it was before this update.
  self.execute("UPDATE runs SET revision = ?, " & assignments & " WHERE run_id = ?",
    @[%self.nextRevision()] & @args & %runId)

proc contains*(self: Database, runId: int): bool =
  ## Whether `runId` was ever saved, by this daemon or an earlier one.
  self.execute("SELECT 1 FROM runs WHERE run_id = ?", runId).len > 0

proc submit*(
    self: Database, deckFile: string, trnrunArgs: seq[string] = @[], label = none(string)
): int =
  ## Saves a new run as `QUEUED` in this session and returns its new `run_id`.
  self.execute("""INSERT INTO runs (session_id, label, revision, state, notices, warnings, fatals,
      submitted_at, deck_file, trnrun_args)
    VALUES (?, ?, ?, ?, 0, 0, 0, """ & Now & ", ?, ?)",
    self.sessionId, label, self.nextRevision(), ssQueued, deckFile, trnrunArgs)
  self.execute("SELECT last_insert_rowid()")[0][0].parseInt()

proc start*(self: Database, runId: int) =
  ## Marks `runId` running once its TRNRun process started.
  self.update(runId, "state = ?, started_at = " & Now, ssRunning)

proc recordSetting(self: Database, runId: int, setting: SettingEvent) =
  ## Replaces the settings of `runId`.
  self.update(runId, "setting = ?", setting)

proc recordStatus(self: Database, runId: int, status: StatusEvent) =
  ## Replaces the latest TRNRun status of `runId`.
  self.update(runId, "trnrun_status = ?, trnrun_message = ?", status.status, status.message)

proc recordConfig(self: Database, runId: int, config: ConfigEvent) =
  ## Replaces the simulation parameters of `runId`.
  self.update(runId, "start_time = ?, stop_time = ?, time_step = ?",
    config.start, config.stop, config.step)

proc recordProgress(self: Database, runId: int, progress: ProgressEvent) =
  ## Replaces the progress of `runId`.
  self.update(runId, "percent = ?, sim_time = ?, elapsed_ms = ?, eta_ms = ?",
    progress.percent, progress.time, progress.elapsedMs, progress.etaMs)

proc recordLog(self: Database, runId: int, log: LogEvent) =
  ## Appends a log entry to `runId` and counts it by severity, atomically.
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

proc record*(self: Database, runId: int, event: SimulationEvent) =
  ## Saves one TRNRun event of `runId`.
  ##
  ## `SETTING`, `STATUS`, `CONFIG` and `PROGRESS` replace the previous value;
  ## each `LOG` is appended and counted by severity, atomically.
  case event.kind
  of eventSetting: self.recordSetting(runId, event.settingData)
  of eventStatus: self.recordStatus(runId, event.statusData)
  of eventConfig: self.recordConfig(runId, event.configData)
  of eventProgress: self.recordProgress(runId, event.progressData)
  of eventLog: self.recordLog(runId, event.logData)

proc finish(
    self: Database, runId: int, exitCode: Option[int], error: string, fallback: StatusEvent
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

proc finish*(self: Database, runId: int, exitCode: Option[int], error: string) =
  ## Marks `runId` finished once TRNRun exited or failed to launch.
  ##
  ## Guarantees a terminal status: when TRNRun did not report one, a
  ## daemon-owned `ERROR` status explains why. Execution errors are kept
  ## independently, even when TRNRun already reported a terminal status.
  let message = if error.len > 0: error else: "TRNRun exited without a terminal status"
  self.finish(runId, exitCode, error, StatusEvent(status: statusError, message: message))

proc cancel*(self: Database, runId: int, started: bool, reason: string) =
  ## Finishes `runId` as stopped before TRNRun exited by itself, without an exit code.
  ##
  ## It is CANCELLED, unless TRNRun already reported a terminal status, and
  ## its error gives `reason` after whether it `started`, such as
  ## `Not started: the daemon shut down` or `Interrupted: cancelled by the client`.
  let outcome = if started: "Interrupted" else: "Not started"
  self.finish(runId, none(int), outcome & ": " & reason,
    StatusEvent(status: statusCancelled, message: outcome))

proc interrupt*(self: Database, reason: string, states: set[SimulationState]) =
  ## Cancels every run in `states`, which the daemon stops tracking before TRNRun exits.
  ##
  ## A queued run never started; a running one did, and its TRNRun is killed
  ## with the daemon.
  let states = toSeq(states)
  self.transaction:
    # Reads every row before finishing any, since finishing changes what the query selects.
    for row in self.execute("SELECT run_id, state FROM runs WHERE state IN (" &
        states.mapIt("?").join(", ") & ") ORDER BY revision", states.mapIt(%it)):
      self.cancel(row[0].parseInt(), started = row[1] != $ssQueued, reason)

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

proc migrate(self: Database) =
  ## Creates the schema in a new database, or refuses one of another version.
  let version = self.execute("PRAGMA user_version")[0][0].parseInt()
  if version == 0:
    self.transaction:
      for statement in Schema:
        self.execute(statement)
      self.execute("PRAGMA user_version = " & $SchemaVersion)
  elif version != SchemaVersion:
    raise newException(DbError, "Database " & self.path & " has schema version " &
      $version & "; this trnrund needs " & $SchemaVersion & ". Use a new database file.")

proc close*(self: Database) =
  ## Closes the database, then releases it to other daemons. Idempotent.
  try:
    if self.connection != nil:
      let connection = self.connection
      self.connection = nil
      connection.close()
  finally:
    if self.lock != 0:
      discard closeHandle(self.lock)
      self.lock = 0

proc openDatabase*(path: string): Database =
  ## Opens or creates the database at `path` and starts a new session in it,
  ## holding the database until `close`; raises `DbError`.
  ##
  ## Runs an earlier daemon left unfinished are finished as interrupted first.
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
    result.revision = result.execute("SELECT coalesce(max(revision), 0) FROM runs")[0][0].parseInt()
    # Runs an earlier daemon left unfinished; this one only runs its own.
    result.interrupt("its daemon stopped unexpectedly", Unfinished)
    result.execute("INSERT INTO sessions (started_at) VALUES (" & Now & ")")
    result.sessionId = result.execute("SELECT last_insert_rowid()")[0][0].parseInt()
  except CatchableError:
    result.close()
    raise
