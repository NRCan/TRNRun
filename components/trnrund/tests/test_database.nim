import std/[json, options, os, strutils, tempfiles, times, unittest]
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
    """{"kind":"PROGRESS","time":4380,"percent":50,"elapsedMs":1234.5,"etaMs":1234.5}"""))
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
    check columns("run", "revision, state, deck_file, notices, warnings, fatals") ==
      @["1", "QUEUED", "deck.dck", "0", "0", "0"]
    check columns("run", """setting IS NULL AND trnrun_status IS NULL AND
      trnrun_message IS NULL AND start_time IS NULL AND sim_time IS NULL AND
      exit_code IS NULL AND error IS NULL AND succeeded IS NULL AND
      started_at IS NULL AND finished_at IS NULL""") == @["1"]

  test "each change bumps the revision and keeps the other columns":
    db.submit("other", "deck.dck")
    db.reported("run")
    check reader.getAllRows(sql"SELECT run_id, revision, state FROM runs ORDER BY revision") ==
      @[@["other", "1", "QUEUED"], @["run", "9", "RUNNING"]]
    check columns("run", Reported) == @[
      "deck.dck", "0.0", "8760.0", "0.25", "4380.0", "50.0", "1234.5", "1234.5", "0", "1", "0"
    ]
    check columns("run", "trnrun_status, trnrun_message") == @["RUNNING", "going"]
    check parseJson(columns("run", "setting")[0]) == %Setting

  test "keeps the latest SETTING, STATUS, CONFIG and PROGRESS":
    db.reported("run")
    db.record("run", statusEvent("DONE", "finished"))
    db.record("run", event("""{"kind":"CONFIG","start":2,"stop":20,"step":0.5}"""))
    db.record("run", event(
      """{"kind":"PROGRESS","time":20,"percent":100,"elapsedMs":9,"etaMs":0}"""))
    check columns("run", """trnrun_status, trnrun_message, start_time, stop_time, time_step,
      sim_time, percent, elapsed_ms, eta_ms""") ==
      @["DONE", "finished", "2.0", "20.0", "0.5", "20.0", "100.0", "9.0", "0.0"]

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
      "deck.dck", "0.0", "8760.0", "0.25", "4380.0", "50.0", "1234.5", "1234.5", "0", "1", "0"
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
    db.interrupt("the client disconnected")

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
    db.interrupt("the daemon shut down")
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
    db.reported("running")
    let before = columns("running", Reported & ", started_at, setting")
    let lastRevision = parseInt(reader.getValue(sql"SELECT max(revision) FROM runs"))
    db.close() # As if the daemon died: nothing marked these runs finished.

    db = openDatabase(path)
    check reader.getValue(sql"SELECT count(*) FROM runs WHERE state != 'FINISHED'") == "0"
    check reader.getAllRows(sql"""SELECT run_id FROM runs
      WHERE revision > ? ORDER BY revision""", lastRevision) == @[@["queued"], @["running"]]
    check columns("queued", "trnrun_status, trnrun_message, error, started_at IS NULL") ==
      @["CANCELLED", "Not started", "Not started: its daemon stopped unexpectedly", "1"]
    check columns("running", "trnrun_status, trnrun_message, error, exit_code IS NULL") ==
      @["CANCELLED", "Interrupted", "Interrupted: its daemon stopped unexpectedly", "1"]
    check columns("running", Reported & ", started_at, setting") == before

  test "only one opener at a time holds a database, until it closes":
    let lockFile = path & ".lock"
    check fileExists(lockFile)
    try:
      discard openDatabase(path)
      fail()
    except DatabaseError as error:
      check "in use by another trnrund" in error.msg
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
    except DatabaseError as error:
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
    expect DatabaseError:
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
    except DatabaseError as error:
      check ("schema version " & $(SchemaVersion + 1)) in error.msg
    check not fileExists(path & ".lock")
    check reader.getValue(sql"SELECT run_id FROM runs") == "kept"
    let restorer = db_sqlite.open(path, "", "", "")
    restorer.exec(sql("PRAGMA user_version = " & $SchemaVersion))
    restorer.close()
    db = openDatabase(path)

  test "cannot open a database in a missing directory":
    expect DatabaseError:
      discard openDatabase(directory / "missing" / "runs.sqlite3")
