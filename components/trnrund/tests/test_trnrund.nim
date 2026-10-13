import std/[json, monotimes, os, osproc, sequtils, streams, strutils, tempfiles, times, unittest]
import db_connector/db_sqlite

import ./fake_trnrun


type CommandResult = object
  output: string
  error: string
  exitCode: int

proc runCommand(
    executable: string, arguments: openArray[string], workingDirectory: string
): CommandResult =
  result = CommandResult(output: "", error: "", exitCode: -1)
  let process = startProcess(
    executable, workingDir = workingDirectory, args = arguments, options = {}
  )
  defer: process.close()
  process.inputStream.close()
  result.output = process.outputStream.readAll()
  result.error = process.errorStream.readAll()
  result.exitCode = process.waitForExit(10_000)

proc request(daemon: Process, line: string): JsonNode =
  daemon.inputStream.writeLine(line)
  daemon.inputStream.flush()
  var reply = ""
  if not daemon.outputStream.readLine(reply):
    raise newException(IOError, "trnrund closed its output")
  parseJson(reply)

proc request(daemon: Process, request: JsonNode): JsonNode =
  daemon.request($request)

proc openReader(daemon: Process): DbConn =
  ## Opens the database `ready` reports, never writing through it.
  let path = daemon.request(%*{"cmd": "ready"})["databasePath"].getStr()
  result = db_sqlite.open(path, "", "", "")
  result.exec(sql"PRAGMA query_only = ON")

proc columns(db: DbConn, runId, expressions: string): Row =
  ## `expressions` on the saved row of `runId`.
  db.getRow(sql("SELECT " & expressions & " FROM runs WHERE run_id = ?"), runId)

proc waitFor(db: DbConn, runId, condition: string) =
  ## Polls the database alone until `condition` holds: the daemon must save while stdin is idle.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    if db.columns(runId, condition) == @["1"]:
      return
    sleep(10)
  raise newException(IOError, "Timed out waiting for " & runId & " in the database")

proc waitForState(db: DbConn, runId, state: string) =
  db.waitFor(runId, "state = '" & state & "'")

proc closeDaemon(daemon: Process) =
  if daemon.running:
    daemon.terminate()
    discard daemon.waitForExit(5_000)
  daemon.close()

proc runTests() =
  const TestVersion = "daemon-test-version"
  let
    daemonDirectory = currentSourcePath().parentDir().parentDir()
    daemonSource = daemonDirectory / "src" / "trnrund.nim"
    testDirectory = createTempDir("trnrund-daemon-", "")
    daemonExecutable = testDirectory / "trnrund-test.exe"
    nimCache = testDirectory / "nimcache"
  defer: removeDir(testDirectory)

  let compiler = findExe("nim")
  let buildResult =
    if compiler.len == 0:
      CommandResult(output: "Nim compiler was not found on PATH", error: "", exitCode: -1)
    else:
      runCommand(compiler, [
        "c", "--hints:off", "--verbosity:0", "--nimcache:" & nimCache,
        "-d:NimblePkgVersion=" & TestVersion, "--out:" & daemonExecutable, daemonSource,
      ], daemonDirectory)

  suite "daemon CLI build":
    test "compiles the daemon test executable":
      if buildResult.exitCode != 0:
        checkpoint(buildResult.output & buildResult.error)
      check buildResult.exitCode == 0
      check fileExists(daemonExecutable)
  if buildResult.exitCode != 0:
    return

  let trnrunOption = "--trnrun:" & getAppFilename()
  var launchNumber = 0
  proc startDaemon(arguments: varargs[string]): Process =
    ## Starts the daemon on a fresh database unless `arguments` name one.
    inc launchNumber
    var arguments = @arguments
    if not arguments.anyIt(it.startsWith("--database:")):
      arguments.add("--database:" & (testDirectory / ($launchNumber & ".sqlite3")))
    startProcess(daemonExecutable, workingDir = testDirectory, args = arguments, options = {})

  suite "daemon CLI":
    test "prints help and version without a TRNRun executable":
      for option in ["-h", "--help"]:
        let command = runCommand(daemonExecutable, [option], testDirectory)
        check command.exitCode == 0
        check command.output.contains("Usage:")
        check command.output.contains("--maxConcurrent:N")
        check command.output.contains("--database:PATH")
        check command.output.contains("--overwrite:true/false")
        check command.output.contains("including idle connections")
        check command.output.contains("No rollback")
        check command.output.contains("deletes the database and its journals")
        check command.output.contains("Commands: ready, add, cancel, shutdown.")
        check command.output.contains("exactly {\"ok\":true}")
        check command.output.contains("with no state field")
        check command.output.contains("Exit codes: 0 ok")
      for option in ["-v", "--version"]:
        let command = runCommand(daemonExecutable, [option], testDirectory)
        check command.exitCode == 0
        check command.output.strip() == TestVersion

    test "reports usage errors on stderr only, with exit code 2":
      let cases = [
        (arguments: @["--doesNotExist"], expected: "Unknown option: --doesNotExist"),
        (arguments: @["-x"], expected: "Unknown option: -x"),
        (arguments: @["extra"], expected: "Unexpected argument: extra"),
        (arguments: @["--maxConcurrent:many"], expected: "many"),
        (arguments: @[trnrunOption, "--maxConcurrent:0"],
          expected: "'maxConcurrent' must be at least 1"),
        (arguments: @["--database:"], expected: "'database' must not be empty"),
        (arguments: @["--overwrite"], expected: "'overwrite' must be true or false"),
        (arguments: @["--overwrite:yes"], expected: "'overwrite' must be true or false"),
        (arguments: @["--trnrun:missing.exe"], expected: "TRNRun not found:"),
        (arguments: newSeq[string](), expected: "TRNRun not found:"),
      ]
      for testCase in cases:
        checkpoint("arguments: " & testCase.arguments.join(" "))
        let command = runCommand(daemonExecutable, testCase.arguments, testDirectory)
        check command.exitCode == 2
        check command.output == ""
        check command.error.contains(testCase.expected)

    test "serves requests in order and saves runs for readers without being asked":
      let
        deckFile = testDirectory / "done.dck"
        path = testDirectory / "my runs.sqlite3"
        daemon = startDaemon(trnrunOption, "--maxConcurrent:2", "--database:" & path)
      defer: daemon.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      check daemon.request(%*{"cmd": "ready"}) == %*{"ok": true, "databasePath": path}
      let reader = daemon.openReader()
      defer: reader.close()
      check daemon.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile}) ==
        %*{"ok": true}

      reader.waitForState("run", "FINISHED")
      check reader.columns("run", "deck_file, succeeded, trnrun_status, percent, notices, warnings") ==
        @[deckFile, "1", "DONE", "1.0", "2", "1"]
      let finished = reader.columns("run", "*")
      var messages: seq[string] = @[]
      for row in reader.rows(sql"SELECT message FROM logs WHERE run_id = 'run' ORDER BY log_id"):
        messages.add(row[0])
      check messages == @["first", "second", "third"]
      check reader.getValue(sql"""SELECT submitted_at <= started_at AND
        started_at <= finished_at FROM runs WHERE run_id = 'run'""") == "1"

      check not daemon.request("garbage")["ok"].getBool()
      check daemon.request(%*{"cmd": "pull"}) == %*{"ok": false, "error": "Unknown cmd: pull"}
      check daemon.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile}) ==
        %*{"ok": false, "error": "Invalid or duplicate runId: run"}
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.waitForExit(5_000) == 0
      check reader.columns("run", "*") == finished

    test "saves progress while both TRNRun and the client are idle":
      let
        deckFile = testDirectory / "progressgate-idle.dck"
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      let reader = daemon.openReader()
      defer: reader.close()
      check daemon.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile}) ==
        %*{"ok": true}
      reader.waitFor("run", "sim_time = 7.5 AND percent = 0.75 AND elapsed_ms = 300 AND eta_ms = 100")
      check reader.columns("run", "state") == @["RUNNING"]
      check not fileExists(deckFile.changeFileExt("released"))
      writeFile(deckFile.changeFileExt("release"), "")
      reader.waitForState("run", "FINISHED")
      check reader.columns("run", "succeeded") == @["1"]
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.waitForExit(5_000) == 0

    test "default and explicit false preserve history; explicit true recreates it and permits ID reuse":
      let
        deckFile = testDirectory / "done-restart.dck"
        databaseOption = "--database:" & (testDirectory / "restart.sqlite3")
      writeFile(deckFile, "fake TRNSYS deck")
      var finished: Row = @[]
      for launch in 1 .. 3:
        checkpoint("launch " & $launch)
        if launch == 3:
          # No readers remain when replacing an incompatible old database.
          let injector = db_sqlite.open(testDirectory / "restart.sqlite3", "", "", "")
          injector.exec(sql"PRAGMA user_version = 999")
          injector.exec(sql"CREATE TABLE obsolete (value TEXT)")
          injector.close()
        block:
          let daemon =
            if launch == 1: startDaemon(trnrunOption, databaseOption)
            elif launch == 2: startDaemon(trnrunOption, databaseOption, "--overwrite:false")
            else: startDaemon(trnrunOption, databaseOption, "--overwrite:true")
          defer: daemon.closeDaemon()
          let reader = daemon.openReader()
          defer: reader.close()
          if launch == 3:
            check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
            check reader.getValue(sql"SELECT count(*) FROM logs") == "0"
            check reader.getValue(sql"PRAGMA user_version") == "2"
            check reader.getValue(sql"PRAGMA journal_mode") == "wal"
            check reader.getValue(sql"SELECT count(*) FROM sqlite_master WHERE name = 'obsolete'") == "0"
          let reply = daemon.request(%*{"cmd": "add", "runId": "historic", "deckFile": deckFile})
          if launch != 2:
            check reply == %*{"ok": true}
            reader.waitForState("historic", "FINISHED")
            finished = reader.columns("historic", "*")
            check reader.getValue(sql"SELECT min(log_id) FROM logs") == "1"
            check reader.getValue(sql"SELECT max(log_id) FROM logs") == "3"
          else:
            check reply == %*{"ok": false, "error": "Invalid or duplicate runId: historic"}
            check reader.columns("historic", "*") == finished
            check reader.getValue(sql"SELECT count(*) FROM logs") == "3"
          check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
          check daemon.waitForExit(5_000) == 0

    test "Windows open connections refuse overwrite before journals are deleted and release ownership":
      let
        path = testDirectory / "busy-overwrite.sqlite3"
        databaseOption = "--database:" & path
        deck = testDirectory / "done-overwrite.dck"
      writeFile(deck, "fake TRNSYS deck")
      block:
        let daemon = startDaemon(trnrunOption, databaseOption, "--overwrite:true")
        defer: daemon.closeDaemon()
        let reader = daemon.openReader()
        defer: reader.close()
        discard daemon.request(%*{"cmd": "add", "runId": "kept", "deckFile": deck})
        reader.waitForState("kept", "FINISHED")
        check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
        check daemon.waitForExit(5_000) == 0
      for mode in ["idle", "reader", "writer"]:
        checkpoint(mode)
        block:
          let blocker = db_sqlite.open(path, "", "", "")
          defer: blocker.close()
          if mode != "idle":
            blocker.exec(sql(if mode == "writer": "BEGIN IMMEDIATE" else: "BEGIN"))
          let rows = blocker.getAllRows(sql"SELECT * FROM runs")
          let logs = blocker.getAllRows(sql"SELECT * FROM logs ORDER BY log_id")
          let main = if mode == "writer": "" else: readFile(path)
          let wal = if mode == "writer": "" else: readFile(path & "-wal")
          let shm = if mode == "writer": "" else: readFile(path & "-shm")
          writeFile(path & "-journal", "untouched journal")
          let command = runCommand(daemonExecutable,
            [trnrunOption, databaseOption, "--overwrite:true"], testDirectory)
          check command.exitCode == 1
          check command.output == ""
          check command.error.contains("cannot delete " & path & ":")
          check command.error.contains("Close all SQLite connections")
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
          check blocker.getAllRows(sql"SELECT * FROM runs") == rows
          check blocker.getAllRows(sql"SELECT * FROM logs ORDER BY log_id") == logs
          if mode != "idle":
            blocker.exec(sql"ROLLBACK")
      let daemon = startDaemon(trnrunOption, databaseOption, "--overwrite:true")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
      check reader.getValue(sql"SELECT count(*) FROM logs") == "0"
      check reader.getValue(sql"PRAGMA journal_mode") == "wal"
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.waitForExit(5_000) == 0

    test "overwrite replaces a non-SQLite file and stale journals before ready":
      let path = testDirectory / "invalid-overwrite.sqlite3"
      let contents = "not a SQLite database"
      writeFile(path, contents)
      let command = runCommand(daemonExecutable,
        [trnrunOption, "--database:" & path, "--overwrite:false"], testDirectory)
      check command.exitCode == 1
      check command.error.contains("not a database")
      check readFile(path) == contents
      check not fileExists(path & ".lock")
      for suffix in ["-wal", "-shm", "-journal"]:
        writeFile(path & suffix, "stale " & suffix)
      let daemon = startDaemon(trnrunOption, "--database:" & path, "--overwrite:true")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      check reader.getValue(sql"PRAGMA integrity_check") == "ok"
      check reader.getValue(sql"PRAGMA user_version") == "2"
      check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
      check not fileExists(path & "-journal")
      check readFile(path & "-wal") != "stale -wal"
      check readFile(path & "-shm") != "stale -shm"
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.waitForExit(5_000) == 0

    test "partial overwrite failure loses old data, reports the file and releases ownership":
      let path = testDirectory / "partial-overwrite.sqlite3"
      writeFile(path, "old data")
      writeFile(path & "-wal", "deleted before failure")
      createDir(path & "-shm")
      writeFile(path & "-journal", "not reached")
      let command = runCommand(daemonExecutable,
        [trnrunOption, "--database:" & path, "--overwrite:true"], testDirectory)
      check command.exitCode == 1
      check command.output == ""
      check command.error.contains("cannot delete " & path & "-shm")
      check command.error.contains("Already deleted files are not restored")
      check not fileExists(path)
      check not fileExists(path & "-wal")
      check dirExists(path & "-shm")
      check readFile(path & "-journal") == "not reached"
      check not fileExists(path & ".lock")
      removeDir(path & "-shm")
      let daemon = startDaemon(trnrunOption, "--database:" & path, "--overwrite:true")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
      check not fileExists(path & "-journal")
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.waitForExit(5_000) == 0

    test "graceful shutdown waits for running runs and cancels queued ones":
      let
        deckFile = testDirectory / "gate-shutdown.dck"
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      let reader = daemon.openReader()
      defer: reader.close()
      discard daemon.request(%*{"cmd": "add", "runId": "active", "deckFile": deckFile})
      reader.waitForState("active", "RUNNING")
      discard daemon.request(%*{"cmd": "add", "runId": "queued", "deckFile": deckFile})
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      reader.waitForState("queued", "FINISHED")
      check reader.columns("queued", "trnrun_status, succeeded") == @["CANCELLED", "0"]
      writeFile(deckFile.changeFileExt("release"), "")
      check daemon.waitForExit(5_000) == 0
      reader.waitForState("active", "FINISHED")
      check reader.columns("active", "succeeded") == @["1"]

    test "cancel kills one running TRNRun and cancels one queued run, leaving the others":
      let
        cancelledDeck = testDirectory / "gate-cancel.dck"
        keptDeck = testDirectory / "done-cancel.dck"
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      writeFile(cancelledDeck, "fake TRNSYS deck")
      writeFile(keptDeck, "fake TRNSYS deck")
      let reader = daemon.openReader()
      defer: reader.close()
      for (runId, deck) in [("running", cancelledDeck), ("queued", keptDeck), ("kept", keptDeck)]:
        check daemon.request(%*{"cmd": "add", "runId": runId, "deckFile": deck}) == %*{"ok": true}
      reader.waitForState("running", "RUNNING")

      check daemon.request(%*{"cmd": "cancel", "runId": "queued"}) == %*{"ok": true}
      check reader.columns("queued", "state, error, started_at IS NULL") ==
        @["FINISHED", "Not started: cancelled by the client", "1"]
      check daemon.request(%*{"cmd": "cancel", "runId": "running"}) == %*{"ok": true}
      reader.waitForState("running", "FINISHED")
      check reader.columns("running", "trnrun_status, error, exit_code IS NULL, succeeded") ==
        @["CANCELLED", "Interrupted: cancelled by the client", "1", "0"]
      reader.waitForState("kept", "FINISHED")
      check reader.columns("kept", "succeeded") == @["1"]

      check daemon.request(%*{"cmd": "cancel", "runId": "kept"}) == %*{"ok": true}
      check reader.columns("kept", "succeeded") == @["1"]
      check daemon.request(%*{"cmd": "cancel", "runId": "missing"}) ==
        %*{"ok": false, "error": "Unknown runId: missing"}
      writeFile(cancelledDeck.changeFileExt("release"), "")
      sleep(300)
      check not fileExists(cancelledDeck.changeFileExt("released"))
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.waitForExit(5_000) == 0

    test "EOF exits immediately, killing running TRNRun and saving it as interrupted":
      let
        deckFile = testDirectory / "gate-orphan.dck"
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      let reader = daemon.openReader()
      defer: reader.close()
      check daemon.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile}) ==
        %*{"ok": true}
      check daemon.request(%*{"cmd": "add", "runId": "queued", "deckFile": deckFile}) ==
        %*{"ok": true}
      check reader.columns("queued", "state") == @["QUEUED"]
      reader.waitForState("run", "RUNNING")
      daemon.inputStream.close()
      check daemon.waitForExit(5_000) == 0
      reader.waitForState("run", "FINISHED")
      check reader.columns("run", "exit_code IS NULL, error") ==
        @["1", "Interrupted: the client disconnected"]
      reader.waitForState("queued", "FINISHED")
      check reader.columns("queued", "error") == @["Not started: the client disconnected"]
      writeFile(deckFile.changeFileExt("release"), "")
      sleep(300)
      check not fileExists(deckFile.changeFileExt("released"))

    test "a second daemon cannot use a database another one holds":
      let
        path = testDirectory / "shared.sqlite3"
        first = startDaemon(trnrunOption, "--database:" & path)
      defer: first.closeDaemon()
      discard first.request(%*{"cmd": "ready"}) # The database is open from here.
      let deck = testDirectory / "done-owned.dck"
      writeFile(deck, "fake TRNSYS deck")
      discard first.request(%*{"cmd": "add", "runId": "owned", "deckFile": deck})
      let reader = first.openReader()
      defer: reader.close()
      reader.waitForState("owned", "FINISHED")
      let before = reader.columns("owned", "*")
      let logs = reader.getAllRows(sql"SELECT * FROM logs ORDER BY log_id")
      let wal = readFile(path & "-wal")
      let shm = readFile(path & "-shm")
      for overwrite in ["false", "true"]:
        let second = runCommand(daemonExecutable,
          [trnrunOption, "--database:" & path, "--overwrite:" & overwrite], testDirectory)
        check second.exitCode == 1
        check second.output == ""
        check second.error.contains("Database is in use by another trnrund")
        check fileExists(path & ".lock")
        check readFile(path & "-wal") == wal
        check readFile(path & "-shm") == shm
        check reader.columns("owned", "*") == before
        check reader.getAllRows(sql"SELECT * FROM logs ORDER BY log_id") == logs

      check first.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check first.waitForExit(5_000) == 0
      let third = startDaemon(trnrunOption, "--database:" & path)
      defer: third.closeDaemon()
      check third.request(%*{"cmd": "ready"})["ok"].getBool()

    test "the next daemon finishes a killed one's runs as interrupted, without running them":
      let
        deckFile = testDirectory / "gate-killed.dck"
        queuedDeck = testDirectory / "done-killed.dck"
        databaseOption = "--database:" & (testDirectory / "killed.sqlite3")
        killed = startDaemon(trnrunOption, "--maxConcurrent:1", databaseOption)
      defer: killed.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      writeFile(queuedDeck, "fake TRNSYS deck")
      let reader = killed.openReader()
      defer: reader.close()
      discard killed.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile})
      discard killed.request(%*{"cmd": "add", "runId": "queued", "deckFile": queuedDeck})
      reader.waitForState("run", "RUNNING")
      killed.kill() # No chance to save anything: the run stays RUNNING.
      discard killed.waitForExit(5_000)
      check reader.columns("run", "state, finished_at IS NULL") == @["RUNNING", "1"]
      check reader.columns("queued", "state") == @["QUEUED"]

      let next = startDaemon(trnrunOption, databaseOption)
      defer: next.closeDaemon()
      discard next.request(%*{"cmd": "ready"})
      reader.waitForState("run", "FINISHED")
      check reader.columns("run", "trnrun_status, error") ==
        @["CANCELLED", "Interrupted: its daemon stopped unexpectedly"]
      check reader.columns("queued", "state, error, started_at IS NULL") ==
        @["FINISHED", "Not started: its daemon stopped unexpectedly", "1"]
      check next.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check next.waitForExit(5_000) == 0

    test "database failures are fatal rather than error replies":
      let
        deckFile = testDirectory / "done-fatal.dck"
        daemon = startDaemon(trnrunOption)
      defer: daemon.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      let path = daemon.request(%*{"cmd": "ready"})["databasePath"].getStr()
      let injector = db_sqlite.open(path, "", "", "")
      injector.exec(sql"""CREATE TRIGGER fail_submission BEFORE INSERT ON runs
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
      injector.close()
      daemon.inputStream.writeLine($(%*{"cmd": "add", "runId": "run", "deckFile": deckFile}))
      daemon.inputStream.flush()
      check daemon.waitForExit(5_000) == 1
      check daemon.outputStream.readAll() == ""
      check daemon.errorStream.readAll().contains("injected failure")
      let reader = db_sqlite.open(path, "", "", "")
      defer: reader.close()
      reader.exec(sql"PRAGMA query_only = ON")
      check reader.getValue(sql"SELECT count(*) FROM runs") == "0"

runTests()
