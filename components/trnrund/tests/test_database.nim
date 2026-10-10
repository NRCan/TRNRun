import std/[json, options, os, strutils, tempfiles, unittest]
import db_connector/db_sqlite

import ../src/[database, events, simulation]


proc finished(runId: string): Simulation =
  result = initSimulation(runId, "deck.dck", @[])
  result.start()
  result.finish(some(0), "")

proc reported(runId: string): Simulation =
  ## A running simulation that TRNRun sent every kind of event.
  result = initSimulation(runId, "deck.dck", @["--pollMs:50"])
  result.start()
  let setting = %SettingEvent(guiVisibility: "hidden", severity: Warning, pollMs: 50)
  setting["kind"] = %"SETTING"
  result.applyLine($setting)
  result.applyLine("""{"kind":"STATUS","status":"RUNNING","message":"going"}""")
  result.applyLine("""{"kind":"CONFIG","start":0,"stop":8760,"step":0.25}""")
  result.applyLine(
    """{"kind":"PROGRESS","time":4380,"percent":50,"elapsedMs":1234.5,"etaMs":1234.5}"""
  )
  result.applyLine("""{"kind":"LOG","severity":"Warning","time":1,"message":"careful"}""")

const Reported = sql"""SELECT deck_file, start_time, stop_time, time_step,
  sim_time, percent, elapsed_ms, eta_ms, notices, warnings, fatals
  FROM runs WHERE run_id = ?"""
  ## Columns `reported` fills that finishing leaves alone.

suite "run database":
  setup:
    let directory = createTempDir("trnrund-database-", "")
    let path = directory / "runs O'Brien été.sqlite3"
    var db = openDatabase(path)
    let reader = db_sqlite.open(path, "", "", "")
    reader.exec(sql"PRAGMA query_only = ON")

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

  test "each save replaces the row, appends logs, and bumps the revision":
    var simulation = initSimulation("run", "deck.dck", @[])
    db.save(simulation)
    check "run" in db
    check reader.getRow(sql"SELECT revision, state FROM runs") == @["1", "QUEUED"]

    simulation.state = ssRunning
    let logs = [
      LogEvent(severity: Warning, time: 1.5, unitId: some(7), message: some("first")),
      LogEvent(severity: Fatal, time: 2),
    ]
    db.save(simulation, logs)
    check reader.getValue(sql"SELECT count(*) FROM runs") == "1"
    check reader.getRow(sql"SELECT revision, state FROM runs") == @["2", "RUNNING"]
    check reader.getAllRows(sql"""SELECT run_id, severity, sim_time, unit_id, type_id,
      message_code, message, information FROM logs ORDER BY log_id""") == @[
      @["run", "Warning", "1.5", "7", "", "", "first", ""],
      @["run", "Fatal", "2.0", "", "", "", "", ""],
    ]
    check reader.getValue(sql"""SELECT count(*) FROM logs
      WHERE type_id IS NULL AND message_code IS NULL AND information IS NULL""") == "2"

  test "saves every field as a column, NULL until TRNRun reports it":
    var simulation = initSimulation("run", "deck.dck", @[])
    db.save(simulation)
    check reader.getValue(sql"""SELECT setting IS NULL AND trnrun_status IS NULL AND
      trnrun_message IS NULL AND start_time IS NULL AND sim_time IS NULL AND
      exit_code IS NULL AND error IS NULL FROM runs""") == "1"
    check reader.getRow(sql"SELECT notices, warnings, fatals, succeeded IS NULL FROM runs") ==
      @["0", "0", "0", "1"]

    simulation = reported("run")
    simulation.finish(some(3), "Lost output")
    db.save(simulation)
    check reader.getRow(Reported, "run") == @[
      "deck.dck", "0.0", "8760.0", "0.25", "4380.0", "50.0", "1234.5", "1234.5", "0", "1", "0"
    ]
    check reader.getRow(sql"SELECT trnrun_status, trnrun_message, exit_code, error, succeeded FROM runs") ==
      @["ERROR", "Lost output", "3", "Lost output", "0"]
    check parseJson(reader.getValue(sql"SELECT setting FROM runs")) == %simulation.setting.get()

  test "saves submission, start, and finish times as columns, NULL until reached":
    const Times = sql"""SELECT submitted_at, started_at IS NULL, finished_at IS NULL
      FROM runs"""
    var simulation = initSimulation("run", "deck.dck", @[])
    db.save(simulation)
    check reader.getRow(Times) == @[simulation.submittedAt, "1", "1"]

    simulation.start()
    db.save(simulation)
    check reader.getValue(sql"SELECT started_at FROM runs") == simulation.startedAt.get()
    check reader.getValue(sql"SELECT finished_at IS NULL FROM runs") == "1"

    simulation.finish(some(0), "")
    db.save(simulation)
    check reader.getRow(sql"SELECT submitted_at, started_at, finished_at FROM runs") == @[
      simulation.submittedAt, simulation.startedAt.get(), simulation.finishedAt.get()
    ]
    let seconds = reader.getValue(sql"""SELECT
      (julianday(finished_at) - julianday(submitted_at)) * 86400 FROM runs""")
    check parseFloat(seconds) in 0.0 .. 5.0

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
    db.save(initSimulation(special, special, @[]),
      [LogEvent(severity: Notice, message: some(special))])
    check special in db
    check "O'Brien" notin db
    check reader.getRow(sql"SELECT run_id, deck_file FROM runs") == @[special, special]
    check reader.getValue(sql"SELECT message FROM logs") == special

  test "reopening keeps every run and continues the revisions":
    db.save(finished("first"))
    db.save(finished("second"))
    db.close()
    db = openDatabase(path)
    check "first" in db
    check "second" in db
    db.save(finished("third"))
    check reader.getAllRows(sql"SELECT run_id, revision FROM runs ORDER BY revision") ==
      @[@["first", "1"], @["second", "2"], @["third", "3"]]

  test "reopening finishes the runs an earlier daemon left unfinished, keeping their fields":
    let running = reported("running")
    db.save(finished("done"))
    db.save(initSimulation("queued", "deck.dck", @[]))
    db.save(running)
    let before = reader.getRow(Reported, "running")
    db.close() # As if the daemon died: nothing marked these runs finished.

    db = openDatabase(path)
    check reader.getValue(sql"SELECT count(*) FROM runs WHERE state != 'FINISHED'") == "0"
    check reader.getAllRows(sql"SELECT run_id, revision FROM runs ORDER BY revision") ==
      @[@["done", "1"], @["queued", "4"], @["running", "5"]]

    check reader.getRow(sql"""SELECT trnrun_status, trnrun_message, error, started_at IS NULL
      FROM runs WHERE run_id = 'queued'""") ==
      @["CANCELLED", "Not started", "Not started: its daemon stopped unexpectedly", "1"]
    check reader.getRow(sql"""SELECT trnrun_status, trnrun_message, error, started_at,
      finished_at IS NOT NULL, exit_code IS NULL FROM runs WHERE run_id = 'running'""") == @[
      "CANCELLED", "Interrupted", "Interrupted: its daemon stopped unexpectedly",
      running.startedAt.get(), "1", "1"
    ]
    check reader.getRow(Reported, "running") == before
    check parseJson(reader.getValue(sql"SELECT setting FROM runs WHERE run_id = 'running'")) ==
      %running.setting.get()

  test "only one opener at a time holds a database, until it closes":
    let lockFile = path & ".lock"
    check fileExists(lockFile)
    try:
      discard openDatabase(path)
      fail()
    except DatabaseError as error:
      check "in use by another trnrund" in error.msg
    db.save(finished("still usable"))
    check "still usable" in db

    db.close()
    check not fileExists(lockFile)
    db = openDatabase(path)
    check "still usable" in db

  test "releases the lock when opening fails partway":
    db.close()
    let injector = db_sqlite.open(path, "", "", "")
    injector.exec(sql"""INSERT INTO runs (run_id, revision, state, deck_file, submitted_at,
        setting, notices, warnings, fatals, succeeded)
      VALUES ('broken', 1, 'RUNNING', 'deck.dck', '2026-01-01T00:00:00.000Z',
        'not JSON', 0, 0, 0, 0)""")
    try:
      discard openDatabase(path)
      fail()
    except DatabaseError as error:
      check "Unreadable run broken" in error.msg
    check not fileExists(path & ".lock")
    injector.exec(sql"DELETE FROM runs")
    injector.close()
    db = openDatabase(path)

  test "a failed save rolls back entirely and leaves the database usable":
    var simulation = initSimulation("run", "deck.dck", @[])
    db.save(simulation)
    let injector = db_sqlite.open(path, "", "", "")
    injector.exec(sql"""CREATE TRIGGER fail_log BEFORE INSERT ON logs
      BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
    simulation.state = ssRunning
    expect DatabaseError:
      db.save(simulation, [LogEvent(severity: Notice)])
    check reader.getValue(sql"SELECT state FROM runs") == "QUEUED"
    injector.exec(sql"DROP TRIGGER fail_log")
    injector.close()
    db.save(simulation, [LogEvent(severity: Notice)])
    check reader.getRow(sql"SELECT revision, state FROM runs") == @["2", "RUNNING"]
    check reader.getValue(sql"SELECT count(*) FROM logs") == "1"

  test "refuses a database of another schema version, keeping its runs":
    db.save(finished("kept"))
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
