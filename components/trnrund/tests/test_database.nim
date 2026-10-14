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

proc settingEvent(setting: SettingEvent): SimulationEvent =
  ## The SETTING event TRNRun sends for `setting`.
  let node = %setting
  node["kind"] = %"SETTING"
  node["timestamp"] = %"2026-06-19T19:37:13"
  event($node)

proc started(db: Database): int =
  ## Saves a new run as submitted and started.
  result = db.submit("deck.dck")
  db.start(result)

proc reported(db: Database): int =
  ## Saves a new run as running after TRNRun sent every kind of event.
  result = db.started()
  db.record(result, settingEvent(Setting))
  db.record(result, statusEvent("RUNNING", "going"))
  db.record(result, event("""{"kind":"CONFIG","start":0,"stop":8760,"step":0.25}"""))
  db.record(result, event(
    """{"kind":"PROGRESS","time":4380,"percent":0.5,"elapsedMs":1234.5,"etaMs":1234.5}"""))
  db.record(result, logEvent("Warning", "careful"))

proc finished(db: Database): int =
  result = db.started()
  db.record(result, statusEvent("DONE"))
  db.finish(result, some(0), "")

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

    proc columns(runId: int, expressions: string): Row =
      reader.getRow(sql("SELECT " & expressions & " FROM runs WHERE run_id = ?"), runId)

  teardown:
    reader.close()
    db.close()
    removeDir(directory)

  test "reports its normalized path and starts a first session in WAL mode, empty":
    check db.path == path.absolutePath().normalizedPath()
    check reader.getValue(sql"PRAGMA journal_mode") == "wal"
    check reader.getValue(sql"PRAGMA user_version") == $SchemaVersion
    check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
    check reader.getAllRows(sql"SELECT session_id FROM sessions WHERE started_at IS NOT NULL") ==
      @[@["1"]]
    check db.sessionId == 1
    check db.revision == 0
    check db.lastLogId == 0
    check 1 notin db

  test "numbers new runs and saves them queued, NULL where TRNRun has not reported yet":
    check db.submit("first.dck") == 1
    check db.submit("second.dck", label = some("my label")) == 2
    check 1 in db
    check db.revision == 2
    check columns(1, "session_id, label IS NULL, revision, state, deck_file, trnrun_args, " &
      "notices, warnings, fatals") == @["1", "1", "1", "QUEUED", "first.dck", "[]", "0", "0", "0"]
    check columns(2, "label, revision") == @["my label", "2"]
    check columns(1, """setting IS NULL AND trnrun_status IS NULL AND
      trnrun_message IS NULL AND start_time IS NULL AND sim_time IS NULL AND
      exit_code IS NULL AND error IS NULL AND succeeded IS NULL AND
      started_at IS NULL AND finished_at IS NULL""") == @["1"]

  test "saves TRNRun arguments as a JSON array":
    let runId = db.submit("deck.dck", @["--pollMs:50", "--guiVisibility:hidden"])
    check parseJson(columns(runId, "trnrun_args")[0]) == %["--pollMs:50", "--guiVisibility:hidden"]

  test "each change bumps the revision and keeps the other columns":
    let other = db.submit("deck.dck")
    let runId = db.reported()
    check reader.getAllRows(sql"SELECT run_id, revision, state FROM runs ORDER BY revision") ==
      @[@[$other, "1", "QUEUED"], @[$runId, "8", "RUNNING"]]
    check db.revision == 8
    check columns(runId, Reported) == @[
      "deck.dck", "0.0", "8760.0", "0.25", "4380.0", "0.5", "1234.5", "1234.5", "0", "1", "0"
    ]
    check columns(runId, "trnrun_status, trnrun_message") == @["RUNNING", "going"]

  test "saves SETTING as JSON, without its kind and timestamp":
    let runId = db.reported()
    check parseJson(columns(runId, "setting")[0]) == %Setting

  test "keeps the latest SETTING, STATUS, CONFIG and PROGRESS":
    let runId = db.reported()
    var newer = Setting
    newer.pollMs = 75
    db.record(runId, settingEvent(newer))
    db.record(runId, statusEvent("DONE", "finished"))
    db.record(runId, event("""{"kind":"CONFIG","start":2,"stop":20,"step":0.5}"""))
    db.record(runId, event(
      """{"kind":"PROGRESS","time":20,"percent":1,"elapsedMs":9,"etaMs":0}"""))
    check parseJson(columns(runId, "setting")[0]) == %newer
    check columns(runId, """trnrun_status, trnrun_message, start_time, stop_time, time_step,
      sim_time, percent, elapsed_ms, eta_ms""") ==
      @["DONE", "finished", "2.0", "20.0", "0.5", "20.0", "1.0", "9.0", "0.0"]

  test "appends each LOG and counts it by severity":
    let runId = db.started()
    for (severity, message) in [
      ("Notice", "first"), ("Warning", "second"), ("Warning", "third"), ("Fatal", "fourth")
    ]:
      db.record(runId, logEvent(severity, message))
    db.record(runId, event(
      """{"kind":"LOG","severity":"Fatal","time":1.5,"unitId":7,"typeId":56,""" &
      """"messageCode":100,"message":"fifth","information":"Check unit 7"}"""))
    check columns(runId, "notices, warnings, fatals") == @["1", "2", "2"]
    check reader.getAllRows(sql"""SELECT run_id, severity, sim_time, unit_id, type_id,
      message_code, message, information FROM logs ORDER BY log_id""") == @[
      @[$runId, "Notice", "0.0", "", "", "", "first", ""],
      @[$runId, "Warning", "0.0", "", "", "", "second", ""],
      @[$runId, "Warning", "0.0", "", "", "", "third", ""],
      @[$runId, "Fatal", "0.0", "", "", "", "fourth", ""],
      @[$runId, "Fatal", "1.5", "7", "56", "100", "fifth", "Check unit 7"],
    ]
    check reader.getValue(sql"""SELECT count(*) FROM logs
      WHERE type_id IS NULL AND message_code IS NULL AND information IS NULL""") == "4"
    check db.lastLogId == 5

  test "stamps submission, start, and finish in UTC ISO 8601 with milliseconds":
    let before = now().utc()
    let runId = db.submit("deck.dck")
    check columns(runId, "started_at IS NULL, finished_at IS NULL") == @["1", "1"]
    db.start(runId)
    check columns(runId, "state, finished_at IS NULL") == @["RUNNING", "1"]
    db.finish(runId, some(0), "")
    let after = now().utc()

    let stamps = columns(runId, "submitted_at, started_at, finished_at")
    for stamp in stamps:
      checkpoint("timestamp: " & stamp)
      let time = parse(stamp, TimestampFormat, utc())
      check time >= before - initDuration(milliseconds = 1)
      check time <= after + initDuration(milliseconds = 1)
    check stamps[0] <= stamps[1]
    check stamps[1] <= stamps[2]

  test "finish keeps TRNRun's terminal status and records the execution error":
    let runId = db.reported()
    db.record(runId, statusEvent("DONE"))
    db.finish(runId, some(0), "Output capture failed")
    check columns(runId, "state, trnrun_status, trnrun_message, exit_code, error, succeeded") ==
      @["FINISHED", "DONE", "", "0", "Output capture failed", "0"]
    check columns(runId, Reported) == @[
      "deck.dck", "0.0", "8760.0", "0.25", "4380.0", "0.5", "1234.5", "1234.5", "0", "1", "0"
    ]

  test "finish adds a daemon ERROR when TRNRun reported no terminal status":
    let cases = [
      (status: "", exitCode: some(0), error: "", expected: "TRNRun exited without a terminal status"),
      (status: "RUNNING", exitCode: some(0), error: "", expected: "TRNRun exited without a terminal status"),
      (status: "", exitCode: none(int), error: "Launch failed", expected: "Launch failed"),
    ]
    for testCase in cases:
      checkpoint($testCase)
      let runId = db.started()
      if testCase.status.len > 0:
        db.record(runId, statusEvent(testCase.status))
      db.finish(runId, testCase.exitCode, testCase.error)
      check columns(runId, "state, trnrun_status, trnrun_message, succeeded") ==
        @["FINISHED", "ERROR", testCase.expected, "0"]

  test "a run that never launched finishes from QUEUED without a start time":
    let runId = db.submit("deck.dck")
    db.finish(runId, none(int), "Requested command not found")
    check columns(runId, "state, started_at IS NULL, exit_code IS NULL, error, succeeded") ==
      @["FINISHED", "1", "1", "Requested command not found", "0"]

  test "succeeds only when finished with DONE, exit code 0, and no error":
    let cases = [
      (status: "DONE", exitCode: some(0), error: "", expected: "1"),
      (status: "DONE", exitCode: some(1), error: "", expected: "0"),
      (status: "DONE", exitCode: none(int), error: "", expected: "0"),
      (status: "DONE", exitCode: some(0), error: "Lost", expected: "0"),
      (status: "ERROR", exitCode: some(0), error: "", expected: "0"),
    ]
    for testCase in cases:
      checkpoint($testCase)
      let runId = db.started()
      db.record(runId, statusEvent(testCase.status))
      check columns(runId, "succeeded") == @[""]
      db.finish(runId, testCase.exitCode, testCase.error)
      check columns(runId, "succeeded") == @[testCase.expected]

  test "interrupt cancels runs in the given states, keeping a terminal status TRNRun reported":
    let
      queued = db.submit("deck.dck")
      running = db.reported()
      done = db.started()
    db.record(done, statusEvent("DONE"))
    let finished = db.finished()
    let finishedRow = columns(finished, "*")

    db.interrupt("the daemon shut down", {ssQueued})
    check columns(running, "state") == @["RUNNING"]
    db.interrupt("the client disconnected", Unfinished)

    const Outcome = """state, trnrun_status, trnrun_message, error, exit_code IS NULL,
      started_at IS NULL, finished_at IS NOT NULL, succeeded"""
    check columns(queued, Outcome) == @["FINISHED", "CANCELLED", "Not started",
      "Not started: the daemon shut down", "1", "1", "1", "0"]
    check columns(running, Outcome) == @["FINISHED", "CANCELLED", "Interrupted",
      "Interrupted: the client disconnected", "1", "0", "1", "0"]
    check columns(done, Outcome) == @["FINISHED", "DONE", "",
      "Interrupted: the client disconnected", "1", "0", "1", "0"]
    check columns(finished, "*") == finishedRow

  test "transactions nest, and readers see their writes only once the outermost commits":
    db.transaction:
      discard db.submit("outer.dck")
      db.transaction:
        discard db.submit("inner.dck")
      check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
    check reader.getValue(sql"SELECT count(*) FROM runs") == "2"

    expect ValueError:
      db.transaction:
        discard db.submit("rolled back.dck")
        db.transaction:
          discard db.submit("also rolled back.dck")
        raise newException(ValueError, "abort")
    check reader.getValue(sql"SELECT count(*) FROM runs") == "2"
    check db.submit("next.dck") == 3 # No reader ever saw the rolled-back ones.

  test "readers polling by revision, by state, by session, or for a run's logs use an index":
    let cases = [
      (query: "SELECT run_id, state FROM runs WHERE revision > 0 ORDER BY revision",
        index: "runs_revision"),
      (query: "SELECT run_id, percent, notices, warnings, fatals FROM runs WHERE state = 'RUNNING'",
        index: "runs_state"),
      (query: "SELECT count(*) FROM runs WHERE state IN ('QUEUED', 'RUNNING')",
        index: "runs_state"),
      (query: "SELECT run_id FROM runs WHERE state = 'QUEUED' ORDER BY revision",
        index: "runs_state"), # A single plan row: no sort.
      (query: "SELECT run_id FROM runs WHERE session_id = 2 ORDER BY revision",
        index: "runs_session"),
      (query: "SELECT * FROM logs WHERE run_id = 1 ORDER BY log_id",
        index: "logs_run_id"),
    ]
    for testCase in cases:
      checkpoint(testCase.query)
      let plan = reader.getAllRows(sql("EXPLAIN QUERY PLAN " & testCase.query))
      check plan.len == 1
      check ("INDEX " & testCase.index) in plan[0][^1] # Also matches COVERING INDEX.

  test "stores apostrophes, Unicode, and SQL-like text verbatim":
    let special = "O'Brien — été 中文 🙂'; DROP TABLE runs; --"
    let runId = db.submit(special, label = some(special))
    db.record(runId, logEvent("Notice", special))
    check reader.getRow(sql"SELECT label, deck_file FROM runs") == @[special, special]
    check reader.getValue(sql"SELECT message FROM logs") == special

  test "reopening keeps every run, starts a new session, and continues numbers and revisions":
    discard db.submit("deck.dck")
    discard db.submit("deck.dck")
    db.interrupt("the daemon shut down", {ssQueued})
    db.close()
    db = openDatabase(path)
    check db.sessionId == 2
    check db.revision == 4
    check 1 in db
    check db.submit("deck.dck") == 3
    check reader.getAllRows(sql"SELECT run_id, session_id, revision FROM runs ORDER BY revision") ==
      @[@["1", "1", "3"], @["2", "1", "4"], @["3", "2", "5"]]

  test "reopening finishes the runs an earlier daemon left unfinished, keeping their fields":
    discard db.finished()
    let
      queued = db.submit("deck.dck")
      running = db.reported()
      before = columns(running, Reported & ", started_at, setting")
      lastRevision = db.revision
    db.close() # As if the daemon died: nothing marked these runs finished.

    db = openDatabase(path)
    check reader.getAllRows(sql"""SELECT run_id, state FROM runs
      WHERE revision > ? ORDER BY revision""", lastRevision) ==
      @[@[$queued, "FINISHED"], @[$running, "FINISHED"]]
    check columns(queued, "trnrun_status, trnrun_message, error, started_at IS NULL") ==
      @["CANCELLED", "Not started", "Not started: its daemon stopped unexpectedly", "1"]
    check columns(running, "trnrun_status, trnrun_message, error, exit_code IS NULL") ==
      @["CANCELLED", "Interrupted", "Interrupted: its daemon stopped unexpectedly", "1"]
    check columns(running, Reported & ", started_at, setting") == before

  test "only one opener at a time holds a database, until it closes":
    let lockFile = path & ".lock"
    check fileExists(lockFile)
    let owned = db.reported()
    let before = columns(owned, "*")
    let logs = reader.getAllRows(sql"SELECT * FROM logs")
    try:
      discard openDatabase(path)
      fail()
    except DbError as error:
      check "in use by another trnrund" in error.msg
    check fileExists(lockFile)
    check columns(owned, "*") == before
    check reader.getAllRows(sql"SELECT * FROM logs") == logs
    let usable = db.submit("deck.dck")
    check usable in db

    db.close()
    db.close() # Idempotent.
    check not fileExists(lockFile)
    db = openDatabase(path)
    check usable in db

  test "releases the lock when opening fails partway":
    let runId = db.started()
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
    check columns(runId, "state") == @["RUNNING"]
    injector.exec(sql"DROP TRIGGER fail_update")
    injector.close()
    db = openDatabase(path)

  test "a failed LOG rolls back entirely and leaves the database usable":
    let runId = db.started()
    let injector = db_sqlite.open(path, "", "", "")
    injector.exec(sql"""CREATE TRIGGER fail_log BEFORE INSERT ON logs
      BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
    expect DbError:
      db.record(runId, logEvent("Notice"))
    check columns(runId, "revision, notices") == @["2", "0"]
    injector.exec(sql"DROP TRIGGER fail_log")
    injector.close()
    db.record(runId, logEvent("Notice"))
    check columns(runId, "revision > 2, notices") == @["1", "1"]
    check reader.getValue(sql"SELECT count(*) FROM logs") == "1"

  test "refuses a database of another schema version, keeping its runs":
    let kept = db.finished()
    db.close()
    for version in [SchemaVersion - 1, SchemaVersion + 1]:
      checkpoint("version " & $version)
      block:
        let injector = db_sqlite.open(path, "", "", "")
        defer: injector.close()
        injector.exec(sql("PRAGMA user_version = " & $version))
      try:
        discard openDatabase(path)
        fail()
      except DbError as error:
        check ("schema version " & $version) in error.msg
        check "Use a new database file" in error.msg
      check not fileExists(path & ".lock")
      check reader.getValue(sql"SELECT run_id FROM runs") == $kept
    let restorer = db_sqlite.open(path, "", "", "")
    restorer.exec(sql("PRAGMA user_version = " & $SchemaVersion))
    restorer.close()
    db = openDatabase(path)

  test "cannot open a database in a missing directory":
    expect DbError:
      discard openDatabase(directory / "missing" / "runs.sqlite3")
