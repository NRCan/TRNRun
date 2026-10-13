import std/[json, options, os, sequtils, strutils, tempfiles, times, unittest]
import db_connector/db_sqlite

import ../src/[database, events]

const TimestampFormat = "yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'"

proc event(line: string): SimulationEvent =
  parseEventLine(line).get()

proc statusEvent(status: string, message = ""): SimulationEvent =
  event($(%*{"kind": "STATUS", "status": status, "message": message}))

proc logEvent(severity: string, message = ""): SimulationEvent =
  event($(%*{"kind": "LOG", "severity": severity, "time": 0, "message": message}))

const Setting = SettingEvent(guiVisibility: "hidden", severity: Warning, pollMs: 50)

proc started(db: Database, runId: string) =
  ## Saves `runId` as submitted, accepted, and started.
  db.submit(runId, "deck.dck")
  db.accept(runId)
  db.start(runId)

proc reported(db: Database, runId: string) =
  ## Saves `runId` as running after TRNRun sent every kind of event.
  db.started(runId)
  let setting = %Setting
  setting["kind"] = %"SETTING"
  db.record(runId, event($setting))
  db.record(runId, statusEvent("RUNNING", "going"))
  db.record(runId, event("""{"kind":"CONFIG","start":0,"stop":8760,"step":0.25}"""))
  db.record(runId, event(
    """{"kind":"PROGRESS","time":4380,"percent":0.5,"elapsedMs":1234.5,"etaMs":1234.5}"""))
  db.record(runId, logEvent("Warning", "careful"))

proc finished(db: Database, runId: string) =
  db.started(runId)
  db.record(runId, statusEvent("DONE"))
  db.finish(runId, some(0), "")

const Reported = """deck_file, start_time, stop_time, time_step,
  sim_time, percent, elapsed_ms, eta_ms, notices, warnings, fatals"""
  ## Columns `reported` fills that finishing leaves alone.

suite "run database":
  setup:
    let directory = createTempDir("trnrund-database-", "")
    let path = directory / "runs O'Brien été.sqlite3"
    var db = openDatabase(path)
    let reader = db_sqlite.open(path, "", "", "")
    reader.exec(sql"PRAGMA query_only = ON")

    proc columns(runId, expressions: string): Row =
      reader.getRow(sql("SELECT " & expressions & " FROM runs WHERE run_id = ?"), runId)

  teardown:
    reader.close()
    db.close()
    removeDir(directory)

  test "reports its normalized path and starts in WAL mode, empty":
    check db.path == path.absolutePath().normalizedPath()
    check reader.getValue(sql"PRAGMA journal_mode") == "wal"
    check reader.getValue(sql"PRAGMA user_version") == $SchemaVersion
    check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
    check "run" notin db

  test "submits a queued run, NULL where TRNRun has not reported yet":
    db.submit("run", "deck.dck")
    check "run" in db
    check columns("run", "revision, state, deck_file, trnrun_args, notices, warnings, fatals") ==
      @["1", "QUEUED", "deck.dck", "[]", "0", "0", "0"]
    check columns("run", """setting IS NULL AND trnrun_status IS NULL AND
      trnrun_message IS NULL AND start_time IS NULL AND sim_time IS NULL AND
      exit_code IS NULL AND error IS NULL AND succeeded IS NULL AND
      started_at IS NULL AND finished_at IS NULL""") == @["1"]

  test "saves TRNRun arguments as a JSON array":
    db.submit("run", "deck.dck", @["--pollMs:50", "--guiVisibility:hidden"])
    check parseJson(columns("run", "trnrun_args")[0]) == %["--pollMs:50", "--guiVisibility:hidden"]

  test "each change bumps the revision and keeps the other columns":
    db.submit("other", "deck.dck")
    db.reported("run")
    check reader.getAllRows(sql"SELECT run_id, revision, state FROM runs ORDER BY revision") ==
      @[@["other", "1", "QUEUED"], @["run", "9", "RUNNING"]]
    check columns("run", Reported) == @[
      "deck.dck", "0.0", "8760.0", "0.25", "4380.0", "0.5", "1234.5", "1234.5", "0", "1", "0"
    ]
    check columns("run", "trnrun_status, trnrun_message") == @["RUNNING", "going"]
    check parseJson(columns("run", "setting")[0]) == %Setting

  test "keeps the latest SETTING, STATUS, CONFIG and PROGRESS":
    db.reported("run")
    db.record("run", statusEvent("DONE", "finished"))
    db.record("run", event("""{"kind":"CONFIG","start":2,"stop":20,"step":0.5}"""))
    db.record("run", event(
      """{"kind":"PROGRESS","time":20,"percent":1,"elapsedMs":9,"etaMs":0}"""))
    check columns("run", """trnrun_status, trnrun_message, start_time, stop_time, time_step,
      sim_time, percent, elapsed_ms, eta_ms""") ==
      @["DONE", "finished", "2.0", "20.0", "0.5", "20.0", "1.0", "9.0", "0.0"]

  test "appends each LOG and counts it by severity":
    db.started("run")
    for (severity, message) in [
      ("Notice", "first"), ("Warning", "second"), ("Warning", "third"), ("Fatal", "fourth")
    ]:
      db.record("run", logEvent(severity, message))
    db.record("run", event(
      """{"kind":"LOG","severity":"Fatal","time":1.5,"unitId":7,"typeId":56,""" &
      """"messageCode":100,"message":"fifth","information":"Check unit 7"}"""))
    check columns("run", "notices, warnings, fatals") == @["1", "2", "2"]
    check reader.getAllRows(sql"""SELECT run_id, severity, sim_time, unit_id, type_id,
      message_code, message, information FROM logs ORDER BY log_id""") == @[
      @["run", "Notice", "0.0", "", "", "", "first", ""],
      @["run", "Warning", "0.0", "", "", "", "second", ""],
      @["run", "Warning", "0.0", "", "", "", "third", ""],
      @["run", "Fatal", "0.0", "", "", "", "fourth", ""],
      @["run", "Fatal", "1.5", "7", "56", "100", "fifth", "Check unit 7"],
    ]
    check reader.getValue(sql"""SELECT count(*) FROM logs
      WHERE type_id IS NULL AND message_code IS NULL AND information IS NULL""") == "4"

  test "stamps submission, start, and finish in UTC ISO 8601 with milliseconds":
    let before = now().utc()
    db.submit("run", "deck.dck")
    check columns("run", "started_at IS NULL, finished_at IS NULL") == @["1", "1"]
    db.accept("run")
    db.start("run")
    check columns("run", "state, finished_at IS NULL") == @["RUNNING", "1"]
    db.finish("run", some(0), "")
    let after = now().utc()

    let stamps = columns("run", "submitted_at, started_at, finished_at")
    for stamp in stamps:
      checkpoint("timestamp: " & stamp)
      let time = parse(stamp, TimestampFormat, utc())
      check time >= before - initDuration(milliseconds = 1)
      check time <= after + initDuration(milliseconds = 1)
    check stamps[0] <= stamps[1]
    check stamps[1] <= stamps[2]

  test "finish keeps TRNRun's terminal status and records the execution error":
    db.reported("run")
    db.record("run", statusEvent("DONE"))
    db.finish("run", some(0), "Output capture failed")
    check columns("run", "state, trnrun_status, trnrun_message, exit_code, error, succeeded") ==
      @["FINISHED", "DONE", "", "0", "Output capture failed", "0"]
    check columns("run", Reported) == @[
      "deck.dck", "0.0", "8760.0", "0.25", "4380.0", "0.5", "1234.5", "1234.5", "0", "1", "0"
    ]

  test "finish adds a daemon ERROR when TRNRun reported no terminal status":
    let cases = [
      (status: "", exitCode: some(0), error: "", expected: "TRNRun exited without a terminal status"),
      (status: "RUNNING", exitCode: some(0), error: "", expected: "TRNRun exited without a terminal status"),
      (status: "", exitCode: none(int), error: "Launch failed", expected: "Launch failed"),
    ]
    for index, testCase in cases:
      checkpoint($testCase)
      let runId = $index
      db.started(runId)
      if testCase.status.len > 0:
        db.record(runId, statusEvent(testCase.status))
      db.finish(runId, testCase.exitCode, testCase.error)
      check columns(runId, "state, trnrun_status, trnrun_message, succeeded") ==
        @["FINISHED", "ERROR", testCase.expected, "0"]

  test "succeeds only when finished with DONE, exit code 0, and no error":
    let cases = [
      (status: "DONE", exitCode: some(0), error: "", expected: "1"),
      (status: "DONE", exitCode: some(1), error: "", expected: "0"),
      (status: "DONE", exitCode: none(int), error: "", expected: "0"),
      (status: "DONE", exitCode: some(0), error: "Lost", expected: "0"),
      (status: "ERROR", exitCode: some(0), error: "", expected: "0"),
    ]
    for index, testCase in cases:
      checkpoint($testCase)
      let runId = $index
      db.started(runId)
      db.record(runId, statusEvent(testCase.status))
      check columns(runId, "succeeded") == @[""]
      db.finish(runId, testCase.exitCode, testCase.error)
      check columns(runId, "succeeded") == @[testCase.expected]

  test "interrupt cancels runs in the given states, keeping a terminal status TRNRun reported":
    db.submit("queued", "deck.dck")
    db.reported("running")
    db.started("done")
    db.record("done", statusEvent("DONE"))
    db.finished("finished")
    let finished = columns("finished", "*")

    db.interrupt("the daemon shut down", {ssQueued})
    check columns("running", "state") == @["RUNNING"]
    db.interrupt("the client disconnected", Unfinished)

    const Outcome = """state, trnrun_status, trnrun_message, error, exit_code IS NULL,
      started_at IS NULL, finished_at IS NOT NULL, succeeded"""
    check columns("queued", Outcome) == @["FINISHED", "CANCELLED", "Not started",
      "Not started: the daemon shut down", "1", "1", "1", "0"]
    check columns("running", Outcome) == @["FINISHED", "CANCELLED", "Interrupted",
      "Interrupted: the client disconnected", "1", "0", "1", "0"]
    check columns("done", Outcome) == @["FINISHED", "DONE", "",
      "Interrupted: the client disconnected", "1", "0", "1", "0"]
    check columns("finished", "*") == finished

  test "readers polling by revision, by state, or for a run's logs use an index":
    let cases = [
      (query: "SELECT run_id, state FROM runs WHERE revision > 0 ORDER BY revision",
        index: "runs_revision"),
      (query: "SELECT run_id, percent, notices, warnings, fatals FROM runs WHERE state = 'RUNNING'",
        index: "runs_state"),
      (query: "SELECT count(*) FROM runs WHERE state IN ('QUEUED', 'ACCEPTED')",
        index: "runs_state"),
      (query: "SELECT run_id FROM runs WHERE state = 'QUEUED' ORDER BY revision",
        index: "runs_state"), # A single plan row: no sort.
      (query: "SELECT * FROM logs WHERE run_id = 'run' ORDER BY log_id",
        index: "logs_run_id"),
    ]
    for testCase in cases:
      checkpoint(testCase.query)
      let plan = reader.getAllRows(sql("EXPLAIN QUERY PLAN " & testCase.query))
      check plan.len == 1
      check ("INDEX " & testCase.index) in plan[0][^1] # Also matches COVERING INDEX.

  test "stores apostrophes, Unicode, and SQL-like text verbatim":
    let special = "O'Brien — été 中文 🙂'; DROP TABLE runs; --"
    db.submit(special, special)
    db.record(special, logEvent("Notice", special))
    check special in db
    check "O'Brien" notin db
    check reader.getRow(sql"SELECT run_id, deck_file FROM runs") == @[special, special]
    check reader.getValue(sql"SELECT message FROM logs") == special

  test "reopening keeps every run and continues the revisions":
    db.submit("first", "deck.dck")
    db.submit("second", "deck.dck")
    db.interrupt("the daemon shut down", {ssQueued})
    db.close()
    db = openDatabase(path)
    check "first" in db
    check "second" in db
    db.submit("third", "deck.dck")
    check reader.getAllRows(sql"SELECT run_id, revision FROM runs ORDER BY revision") ==
      @[@["first", "3"], @["second", "4"], @["third", "5"]]

  test "reopening finishes the runs an earlier daemon left unfinished, keeping their fields":
    db.finished("done")
    db.submit("queued", "deck.dck")
    db.submit("accepted", "deck.dck")
    db.accept("accepted")
    db.reported("running")
    let before = columns("running", Reported & ", started_at, setting")
    let lastRevision = parseInt(reader.getValue(sql"SELECT max(revision) FROM runs"))
    db.close() # As if the daemon died: nothing marked these runs finished.

    db = openDatabase(path)
    check reader.getAllRows(sql"""SELECT run_id, state FROM runs
      WHERE revision > ? ORDER BY revision""", lastRevision) ==
      @[@["queued", "FINISHED"], @["accepted", "FINISHED"], @["running", "FINISHED"]]
    check columns("queued", "trnrun_status, trnrun_message, error, started_at IS NULL") ==
      @["CANCELLED", "Not started", "Not started: its daemon stopped unexpectedly", "1"]
    check columns("running", "trnrun_status, trnrun_message, error, exit_code IS NULL") ==
      @["CANCELLED", "Interrupted", "Interrupted: its daemon stopped unexpectedly", "1"]
    check columns("running", Reported & ", started_at, setting") == before

  test "only one opener at a time holds a database, until it closes":
    let lockFile = path & ".lock"
    check fileExists(lockFile)
    db.reported("owned")
    let before = columns("owned", "*")
    let logs = reader.getAllRows(sql"SELECT * FROM logs")
    let wal = readFile(path & "-wal")
    let shm = readFile(path & "-shm")
    for overwrite in [false, true]:
      try:
        discard openDatabase(path, overwrite)
        fail()
      except DbError as error:
        check "in use by another trnrund" in error.msg
      check fileExists(lockFile)
      check readFile(path & "-wal") == wal
      check readFile(path & "-shm") == shm
      check columns("owned", "*") == before
      check reader.getAllRows(sql"SELECT * FROM logs") == logs
    db.submit("still usable", "deck.dck")
    check "still usable" in db

    db.close()
    check not fileExists(lockFile)
    db = openDatabase(path)
    check "still usable" in db

  test "releases the lock when opening fails partway":
    db.started("run")
    db.close()
    let injector = db_sqlite.open(path, "", "", "")
    injector.exec(sql"""CREATE TRIGGER fail_update BEFORE UPDATE ON runs
      BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
    try:
      discard openDatabase(path)
      fail()
    except DbError as error:
      check "injected failure" in error.msg
    check not fileExists(path & ".lock")
    check columns("run", "state") == @["RUNNING"]
    injector.exec(sql"DROP TRIGGER fail_update")
    injector.close()
    db = openDatabase(path)

  test "a failed LOG rolls back entirely and leaves the database usable":
    db.started("run")
    let injector = db_sqlite.open(path, "", "", "")
    injector.exec(sql"""CREATE TRIGGER fail_log BEFORE INSERT ON logs
      BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
    expect DbError:
      db.record("run", logEvent("Notice"))
    check columns("run", "revision, notices") == @["3", "0"]
    injector.exec(sql"DROP TRIGGER fail_log")
    injector.close()
    db.record("run", logEvent("Notice"))
    check columns("run", "revision, notices") == @["4", "1"]
    check reader.getValue(sql"SELECT count(*) FROM logs") == "1"

  test "refuses a database of another schema version, keeping its runs":
    db.finished("kept")
    db.close()
    let injector = db_sqlite.open(path, "", "", "")
    injector.exec(sql("PRAGMA user_version = " & $(SchemaVersion + 1)))
    injector.close()
    try:
      discard openDatabase(path)
      fail()
    except DbError as error:
      check ("schema version " & $(SchemaVersion + 1)) in error.msg
    check not fileExists(path & ".lock")
    check reader.getValue(sql"SELECT run_id FROM runs") == "kept"
    let restorer = db_sqlite.open(path, "", "", "")
    restorer.exec(sql("PRAGMA user_version = " & $SchemaVersion))
    restorer.close()
    db = openDatabase(path)

  test "cannot open a database in a missing directory":
    for overwrite in [false, true]:
      expect DbError:
        discard openDatabase(directory / "missing" / "runs.sqlite3", overwrite)

suite "explicit database overwrite":
  setup:
    let directory = createTempDir("trnrund-overwrite-", "")
    let path = directory / "runs.sqlite3"
    block:
      let db = openDatabase(path)
      db.reported("reusable")
      db.record("reusable", logEvent("Notice", "old log"))
      db.finished("finished")
      db.close()

  teardown:
    removeDir(directory)

  test "explicit false preserves rows, logs, IDs and unfinished-run recovery":
    let db = openDatabase(path, overwrite = false)
    defer: db.close()
    let reader = db_sqlite.open(path, "", "", "")
    defer: reader.close()
    check "reusable" in db
    check reader.getRow(sql"SELECT state, error FROM runs WHERE run_id = 'reusable'") ==
      @["FINISHED", "Interrupted: its daemon stopped unexpectedly"]
    check reader.getValue(sql"SELECT count(*) FROM logs") == "2"
    expect DbError:
      db.submit("reusable", "new.dck")

  test "recreation clears runs, logs, old schema and version, restarting counters":
    block:
      let injector = db_sqlite.open(path, "", "", "")
      defer: injector.close()
      injector.exec(sql"ALTER TABLE runs ADD COLUMN old_column TEXT")
      injector.exec(sql"CREATE TABLE obsolete (value TEXT)")
      injector.exec(sql"CREATE VIEW old_view AS SELECT * FROM runs")
      injector.exec(sql"CREATE INDEX old_index ON runs (deck_file)")
      injector.exec(sql"""CREATE TRIGGER old_trigger BEFORE INSERT ON runs
        BEGIN SELECT RAISE(ABORT, 'old trigger'); END""")
      injector.exec(sql"PRAGMA user_version = 999")
    let db = openDatabase(path, overwrite = true)
    defer: db.close()
    let reader = db_sqlite.open(path, "", "", "")
    defer: reader.close()
    check reader.getValue(sql"PRAGMA journal_mode") == "wal"
    check reader.getValue(sql"PRAGMA user_version") == $SchemaVersion
    check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
    check reader.getValue(sql"SELECT count(*) FROM logs") == "0"
    check reader.getValue(sql"""SELECT count(*) FROM sqlite_master
      WHERE name IN ('obsolete', 'old_view', 'old_index', 'old_trigger')""") == "0"
    check not reader.getAllRows(sql"PRAGMA table_info(runs)").anyIt(it[1] == "old_column")
    db.submit("reusable", "new.dck")
    check reader.getValue(sql"SELECT revision FROM runs") == "1"
    db.record("reusable", logEvent("Notice", "new log"))
    check reader.getRow(sql"SELECT log_id, message FROM logs") == @["1", "new log"]
    check reader.getValue(sql"SELECT revision FROM runs") == "2"

  test "overwrite also creates a missing database":
    let missing = directory / "missing.sqlite3"
    let db = openDatabase(missing, overwrite = true)
    defer: db.close()
    let reader = db_sqlite.open(missing, "", "", "")
    defer: reader.close()
    check reader.getValue(sql"PRAGMA journal_mode") == "wal"
    check reader.getValue(sql"PRAGMA user_version") == $SchemaVersion
    db.submit("first", "deck.dck")
    check reader.getValue(sql"SELECT revision FROM runs") == "1"

  test "Windows open connections refuse main-file deletion before journal cleanup":
    for mode in ["idle", "reader", "writer"]:
      checkpoint(mode)
      block:
        let contender = db_sqlite.open(path, "", "", "")
        defer: contender.close()
        if mode != "idle":
          contender.exec(sql(if mode == "writer": "BEGIN IMMEDIATE" else: "BEGIN"))
        let rows = contender.getAllRows(sql"SELECT * FROM runs ORDER BY run_id")
        let logs = contender.getAllRows(sql"SELECT * FROM logs ORDER BY log_id")
        let main = if mode == "writer": "" else: readFile(path)
        let wal = if mode == "writer": "" else: readFile(path & "-wal")
        let shm = if mode == "writer": "" else: readFile(path & "-shm")
        writeFile(path & "-journal", "untouched journal")
        try:
          discard openDatabase(path, overwrite = true)
          fail()
        except DbError as error:
          check ("cannot delete " & path & ":") in error.msg
          check "Close all SQLite connections" in error.msg
        check not fileExists(path & ".lock")
        check fileExists(path)
        check fileExists(path & "-wal")
        check fileExists(path & "-shm")
        if mode != "writer":
          check readFile(path) == main
          check readFile(path & "-wal") == wal
          check readFile(path & "-shm") == shm
        check readFile(path & "-journal") == "untouched journal"
        removeFile(path & "-journal")
        check contender.getAllRows(sql"SELECT * FROM runs ORDER BY run_id") == rows
        check contender.getAllRows(sql"SELECT * FROM logs ORDER BY log_id") == logs
        if mode != "idle":
          contender.exec(sql"ROLLBACK")
      let db = openDatabase(path, overwrite = true)
      db.reported("reusable")
      db.close()

  test "overwrite removes stale WAL, SHM and rollback journals before SQLite opens":
    for mainExists in [true, false]:
      checkpoint("main exists: " & $mainExists)
      if not mainExists:
        removeFile(path)
      for suffix in ["-wal", "-shm", "-journal"]:
        writeFile(path & suffix, "stale " & suffix)
      block:
        let db = openDatabase(path, overwrite = true)
        defer: db.close()
        let reader = db_sqlite.open(path, "", "", "")
        defer: reader.close()
        check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
        check reader.getValue(sql"PRAGMA integrity_check") == "ok"
        check not fileExists(path & "-journal")
        check readFile(path & "-wal") != "stale -wal"
        check readFile(path & "-shm") != "stale -shm"
        check fileExists(path & ".lock")
        expect DbError:
          discard openDatabase(path, overwrite = true)

  test "partial deletion is not rolled back and releases ownership for retry":
    writeFile(path & "-wal", "deleted before failure")
    createDir(path & "-shm") # DeleteFile refuses a directory; no permissions workaround.
    writeFile(path & "-journal", "not reached")
    try:
      discard openDatabase(path, overwrite = true)
      fail()
    except DbError as error:
      check ("cannot delete " & path & "-shm") in error.msg
      check "Already deleted files are not restored" in error.msg
    check not fileExists(path)
    check not fileExists(path & "-wal")
    check dirExists(path & "-shm")
    check readFile(path & "-journal") == "not reached"
    check not fileExists(path & ".lock")
    removeDir(path & "-shm")
    let db = openDatabase(path, overwrite = true)
    defer: db.close()
    check "reusable" notin db
    check "finished" notin db
    check not fileExists(path & "-journal")

  test "overwrite replaces non-SQLite and corrupt databases; default preserves them":
    for contents in ["not a SQLite database", "SQLite format 3\x00" & repeat('x', 4096)]:
      writeFile(path, contents)
      expect DbError:
        discard openDatabase(path)
      check readFile(path) == contents
      check not fileExists(path & ".lock")
      block:
        let db = openDatabase(path, overwrite = true)
        defer: db.close()
        let reader = db_sqlite.open(path, "", "", "")
        defer: reader.close()
        check reader.getValue(sql"PRAGMA integrity_check") == "ok"
        check reader.getValue(sql"PRAGMA user_version") == $SchemaVersion
        check reader.getValue(sql"PRAGMA journal_mode") == "wal"
        check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
