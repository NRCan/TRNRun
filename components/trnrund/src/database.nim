## SQLite database for simulations

import std/[json, options, os, oserrors, strutils, winlean]
import db_connector/db_sqlite
from db_connector/sqlite3 import PStmt, SQLITE_DONE, SQLITE_ROW, column_text, step
import ./[events, simulation]

type
  DatabaseError* = DbError

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

template field(event: Option, name: untyped): untyped =
  ## The `name` field of `event`, or none before TRNRun reported it.
  (if event.isSome: some(event.get().name) else: none(typeof(event.get().name)))

proc save*(self: Database, simulation: Simulation, logs: openArray[LogEvent] = []) =
  ## Atomically replaces the row of `simulation` and appends `logs`.
  self.transaction:
    self.execute("""INSERT OR REPLACE INTO runs (run_id, revision, state,
        trnrun_status, trnrun_message, percent, sim_time, elapsed_ms, eta_ms,
        notices, warnings, fatals,
        succeeded, exit_code, error,
        submitted_at, started_at, finished_at,
        deck_file, start_time, stop_time, time_step, setting)
      VALUES (?, (SELECT coalesce(max(revision), 0) + 1 FROM runs), ?,
        ?, ?, ?, ?, ?, ?,
        ?, ?, ?,
        ?, ?, nullif(?, ''),
        ?, ?, ?,
        ?, ?, ?, ?, ?)""",
      simulation.runId, simulation.state,
      simulation.status.field(status), simulation.status.field(message),
      simulation.progress.field(percent), simulation.progress.field(time),
      simulation.progress.field(elapsedMs), simulation.progress.field(etaMs),
      simulation.notices, simulation.warnings, simulation.fatals,
      if simulation.state == ssFinished: some(simulation.succeeded()) else: none(bool),
      simulation.exitCode, simulation.error,
      simulation.submittedAt, simulation.startedAt, simulation.finishedAt,
      simulation.deckFile, simulation.config.field(start), simulation.config.field(stop),
      simulation.config.field(step), simulation.setting)
    for log in logs:
      self.execute("""INSERT INTO logs (run_id, severity, sim_time,
          unit_id, type_id, message_code, message, information)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
        simulation.runId, log.severity, log.time,
        log.unitId, log.typeId, log.messageCode, log.message, log.information)

proc contains*(self: Database, runId: string): bool =
  ## Whether `runId` was ever saved, by this daemon or an earlier one.
  self.execute("SELECT 1 FROM runs WHERE run_id = ?", runId).isSome

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

proc readRun(row: Row): Simulation =
  ## Rebuilds a simulation from `interruptUnfinished`'s columns; TRNRun arguments are not stored.
  template optional(index: int, value: untyped): untyped =
    (if row[index].len == 0: none(typeof(value)) else: some(value))
  Simulation(
    runId: row[0],
    state: parseEnum[SimulationState](row[1]),
    status: optional(2, StatusEvent(status: parseEnum[SimStatus](row[2]), message: row[3])),
    progress: optional(4, ProgressEvent(percent: parseFloat(row[4]),
      time: parseFloat(row[5]), elapsedMs: parseFloat(row[6]), etaMs: parseFloat(row[7]))),
    notices: parseInt(row[8]),
    warnings: parseInt(row[9]),
    fatals: parseInt(row[10]),
    exitCode: optional(11, parseInt(row[11])),
    error: row[12],
    submittedAt: row[13],
    startedAt: optional(14, row[14]),
    finishedAt: optional(15, row[15]),
    deckFile: row[16],
    config: optional(17, ConfigEvent(
      start: parseFloat(row[17]), stop: parseFloat(row[18]), step: parseFloat(row[19]))),
    setting: optional(20, parseJson(row[20]).to(SettingEvent)),
  )

proc interruptUnfinished(self: Database) =
  ## Finishes as interrupted every run an earlier daemon left unfinished.
  for row in self.connection.getAllRows(sql"""SELECT run_id, state,
      trnrun_status, trnrun_message, percent, sim_time, elapsed_ms, eta_ms,
      notices, warnings, fatals,
      exit_code, error,
      submitted_at, started_at, finished_at,
      deck_file, start_time, stop_time, time_step, setting
    FROM runs WHERE state != 'FINISHED' ORDER BY revision"""):
    var simulation =
      try:
        readRun(row)
      except KeyError, ValueError:
        raise newException(DatabaseError,
          "Unreadable run " & row[0] & ": " & getCurrentExceptionMsg())
    simulation.interrupt("its daemon stopped unexpectedly")
    self.save(simulation)

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
    result.interruptUnfinished()
  except CatchableError:
    result.close()
    raise
