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
        check command.output.contains("Commands: ready, add, shutdown.")
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
        %*{"ok": true, "state": "ACCEPTED"}

      reader.waitForState("run", "FINISHED")
      check reader.columns("run", "deck_file, succeeded, trnrun_status, percent, notices, warnings") ==
        @[deckFile, "1", "DONE", "100.0", "2", "1"]
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
        %*{"ok": true, "state": "ACCEPTED"}
      reader.waitFor("run", "sim_time = 7.5 AND percent = 75 AND elapsed_ms = 300 AND eta_ms = 100")
      check reader.columns("run", "state") == @["RUNNING"]
      check not fileExists(deckFile.changeFileExt("released"))
      writeFile(deckFile.changeFileExt("release"), "")
      reader.waitForState("run", "FINISHED")
      check reader.columns("run", "succeeded") == @["1"]
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.waitForExit(5_000) == 0

    test "add with until replies once the run reaches it, then serves later requests":
      let
        deckFile = testDirectory / "done-until.dck"
        daemon = startDaemon(trnrunOption)
      defer: daemon.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      let reader = daemon.openReader()
      defer: reader.close()
      daemon.inputStream.writeLine($(%*{
        "cmd": "add", "runId": "run", "deckFile": deckFile, "until": "FINISHED"}))
      daemon.inputStream.writeLine($(%*{"cmd": "shutdown"})) # Sent before the reply.
      daemon.inputStream.flush()
      var line = ""
      check daemon.outputStream.readLine(line)
      check parseJson(line) == %*{"ok": true, "state": "FINISHED"}
      check reader.columns("run", "state, succeeded") == @["FINISHED", "1"]
      check daemon.outputStream.readLine(line)
      check parseJson(line) == %*{"ok": true}
      check daemon.waitForExit(5_000) == 0

    test "runIds stay taken after restarting against the same database":
      let
        deckFile = testDirectory / "done-restart.dck"
        databaseOption = "--database:" & (testDirectory / "restart.sqlite3")
      writeFile(deckFile, "fake TRNSYS deck")
      var finished: Row = @[]
      for launch in 1 .. 2:
        checkpoint("launch " & $launch)
        block:
          let daemon = startDaemon(trnrunOption, databaseOption)
          defer: daemon.closeDaemon()
          let reader = daemon.openReader()
          defer: reader.close()
          let reply = daemon.request(%*{"cmd": "add", "runId": "historic", "deckFile": deckFile})
          if launch == 1:
            check reply == %*{"ok": true, "state": "ACCEPTED"}
            reader.waitForState("historic", "FINISHED")
            finished = reader.columns("historic", "*")
          else:
            check reply == %*{"ok": false, "error": "Invalid or duplicate runId: historic"}
            check reader.columns("historic", "*") == finished
            check reader.getValue(sql"SELECT count(*) FROM logs") == "3"
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

    test "EOF exits immediately, killing running TRNRun and saving it as interrupted":
      let
        deckFile = testDirectory / "gate-orphan.dck"
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      let reader = daemon.openReader()
      defer: reader.close()
      check daemon.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile}) ==
        %*{"ok": true, "state": "ACCEPTED"}
      check daemon.request(%*{"cmd": "add", "runId": "queued", "deckFile": deckFile}) ==
        %*{"ok": true, "state": "QUEUED"}
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

      let second = runCommand(daemonExecutable, [trnrunOption, "--database:" & path], testDirectory)
      check second.exitCode == 1
      check second.output == ""
      check second.error.contains("Database is in use by another trnrund")

      check first.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check first.waitForExit(5_000) == 0
      let third = startDaemon(trnrunOption, "--database:" & path)
      defer: third.closeDaemon()
      check third.request(%*{"cmd": "ready"})["ok"].getBool()

    test "a killed daemon's runs are finished as interrupted by the next one":
      let
        deckFile = testDirectory / "gate-killed.dck"
        databaseOption = "--database:" & (testDirectory / "killed.sqlite3")
        killed = startDaemon(trnrunOption, databaseOption)
      defer: killed.closeDaemon()
      writeFile(deckFile, "fake TRNSYS deck")
      let reader = killed.openReader()
      defer: reader.close()
      discard killed.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile})
      reader.waitForState("run", "RUNNING")
      killed.kill() # No chance to save anything: the run stays RUNNING.
      discard killed.waitForExit(5_000)
      check reader.columns("run", "state, finished_at IS NULL") == @["RUNNING", "1"]

      let next = startDaemon(trnrunOption, databaseOption)
      defer: next.closeDaemon()
      discard next.request(%*{"cmd": "ready"})
      reader.waitForState("run", "FINISHED")
      check reader.columns("run", "trnrun_status, error") ==
        @["CANCELLED", "Interrupted: its daemon stopped unexpectedly"]
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

runTests()
