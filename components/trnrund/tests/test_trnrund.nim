import std/[json, monotimes, os, osproc, sequtils, streams, strutils, tempfiles, times, unittest]
import db_connector/db_sqlite

import ./[fake_deck, fake_trnrun]

type
  CommandResult = object
    output: string
    error: string
    exitCode: int

  Daemon = ref object
    ## A running trnrund and the notifications read while waiting for replies.
    process: Process
    events: seq[JsonNode]

proc runCommand(
    executable: string, arguments: openArray[string], workingDirectory: string
): CommandResult =
  ## Runs `executable` with stdin closed and returns its output, error output, and exit code.
  let process = startProcess(
    executable, workingDir = workingDirectory, args = arguments, options = {}
  )
  defer: process.close()
  process.inputStream.close()
  let
    output = process.outputStream.readAll()
    error = process.errorStream.readAll()
  result = CommandResult(output: output, error: error, exitCode: process.waitForExit(10_000))

proc send(daemon: Daemon, line: string) =
  ## Writes one request line to the daemon's stdin.
  daemon.process.inputStream.writeLine(line)
  daemon.process.inputStream.flush()

proc readMessage(daemon: Daemon): JsonNode =
  ## The next stdout line, a reply or a notification.
  var line = ""
  if not daemon.process.outputStream.readLine(line):
    raise newException(IOError, "trnrund closed its output")
  parseJson(line)

proc request(daemon: Daemon, line: string): JsonNode =
  ## Sends one request and returns its reply, keeping notifications read meanwhile.
  daemon.send(line)
  result = daemon.readMessage()
  while "event" in result:
    daemon.events.add(result)
    result = daemon.readMessage()

proc request(daemon: Daemon, request: JsonNode): JsonNode =
  ## Sends `request` and returns its reply, keeping notifications read meanwhile.
  daemon.request($request)

proc add(daemon: Daemon, deckFile: string): int =
  ## Adds a run and returns its runId.
  let reply = daemon.request(%*{"cmd": "add", "deckFile": deckFile})
  doAssert reply["ok"].getBool(), $reply
  reply["runId"].getInt()

proc readRemaining(daemon: Daemon): seq[JsonNode] =
  ## Every line until stdout ends.
  result = @[]
  var line = ""
  while daemon.process.outputStream.readLine(line):
    result.add(parseJson(line))

proc openReader(daemon: Daemon): DbConn =
  ## Opens the database `ready` reports, never writing through it.
  let path = daemon.request(%*{"cmd": "ready"})["databasePath"].getStr()
  result = db_sqlite.open(path, "", "", "")
  result.exec(sql"PRAGMA query_only = ON")

proc columns(db: DbConn, runId: int, expressions: string): Row =
  ## `expressions` on the saved row of `runId`.
  db.getRow(sql("SELECT " & expressions & " FROM runs WHERE run_id = ?"), runId)

proc waitFor(db: DbConn, runId: int, condition: string) =
  ## Polls the database alone until `condition` holds: the daemon must save while stdin is idle.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    if db.columns(runId, condition) == @["1"]:
      return
    sleep(10)
  raise newException(IOError, "Timed out waiting for run " & $runId & " in the database")

proc waitForState(db: DbConn, runId: int, state: string) =
  ## Polls the database until `runId` is in `state`.
  db.waitFor(runId, "state = '" & state & "'")

proc closeDaemon(daemon: Daemon) =
  ## Terminates the daemon if it still runs, then closes its process.
  if daemon.process.running:
    daemon.process.terminate()
    discard daemon.process.waitForExit(5_000)
  daemon.process.close()

proc runTests() =
  ## Builds the daemon, then runs the CLI tests against it in a temporary directory.
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
      CommandResult(output: "Nim compiler was not found on PATH", exitCode: -1)
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
  proc startDaemon(arguments: varargs[string]): Daemon =
    ## Starts the daemon on a fresh database unless `arguments` name one.
    inc launchNumber
    var arguments = @arguments
    if not arguments.anyIt(it.startsWith("--database:")):
      arguments.add("--database:" & (testDirectory / ($launchNumber & ".sqlite3")))
    Daemon(process: startProcess(daemonExecutable, workingDir = testDirectory,
      args = arguments, options = {}))

  proc deck(name: string): string =
    ## Writes a placeholder deck named `name` in the test directory.
    createDeck(testDirectory, name)

  suite "daemon CLI":
    test "prints help and version without a TRNRun executable":
      for option in ["-h", "--help"]:
        let command = runCommand(daemonExecutable, [option], testDirectory)
        check command.exitCode == 0
        check command.output.contains("Usage:")
        check command.output.contains("--maxConcurrent:N")
        check command.output.contains("--database:PATH")
        check command.output.contains("Commands: ready, add, cancel, shutdown.")
        check command.output.contains("README.md")
        check command.output.contains("Exit codes: 0 ok")
        check not command.output.contains("overwrite")
      for option in ["-v", "--version"]:
        let command = runCommand(daemonExecutable, [option], testDirectory)
        check command.exitCode == 0
        check command.output.strip() == TestVersion

    test "reports usage errors on stderr only, with exit code 2":
      let cases = [
        (arguments: @["--doesNotExist"], expected: "Unknown option: --doesNotExist"),
        (arguments: @["-x"], expected: "Unknown option: -x"),
        (arguments: @["extra"], expected: "Unexpected argument: extra"),
        (arguments: @["--overwrite:true"], expected: "Unknown option: --overwrite"),
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

    test "serves requests in order, numbers runs, and saves them for readers without being asked":
      let
        deckFile = deck("done.dck")
        path = testDirectory / "my runs.sqlite3"
        daemon = startDaemon(trnrunOption, "--maxConcurrent:2", "--database:" & path)
      defer: daemon.closeDaemon()
      check daemon.request(%*{"id": "r1", "cmd": "ready"}) == %*{
        "id": "r1", "ok": true, "databasePath": path, "sessionId": 1, "revision": 0, "logId": 0
      }
      let reader = daemon.openReader()
      defer: reader.close()
      check daemon.request(%*{"id": 2, "cmd": "add", "deckFile": deckFile, "label": "first"}) ==
        %*{"id": 2, "ok": true, "runId": 1}

      reader.waitForState(1, "FINISHED")
      check reader.columns(1, "deck_file, label, session_id, succeeded, trnrun_status, " &
        "percent, notices, warnings") == @[deckFile, "first", "1", "1", "DONE", "1.0", "2", "1"]
      let finished = reader.columns(1, "*")
      var messages: seq[string] = @[]
      for row in reader.rows(sql"SELECT message FROM logs WHERE run_id = 1 ORDER BY log_id"):
        messages.add(row[0])
      check messages == @["first", "second", "third"]
      check reader.getValue(sql"""SELECT submitted_at <= started_at AND
        started_at <= finished_at FROM runs WHERE run_id = 1""") == "1"

      check not daemon.request("garbage")["ok"].getBool()
      check daemon.request(%*{"cmd": "pull"}) == %*{"ok": false, "error": "Unknown cmd: pull"}
      check daemon.add(deckFile) == 2
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.readRemaining().allIt("event" in it) # Every reply was read.
      check daemon.process.waitForExit(5_000) == 0
      check reader.columns(1, "*") == finished

    test "every client is notified of saved changes, until stdout ends after the last one":
      let
        deckFile = deck("progressgate-notified.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      let runId = daemon.add(deckFile)

      # Notifications arrive while both TRNRun and the client are idle.
      var revision = 0
      while reader.columns(runId, "percent = 0.75")[0] != "1":
        let message = if daemon.events.len > 0: daemon.events.pop() else: daemon.readMessage()
        check message["event"].getStr() == "changed"
        check message["revision"].getInt() > revision
        revision = message["revision"].getInt()
        check $revision <= reader.getValue(sql"SELECT max(revision) FROM runs")
      daemon.events = @[]
      check reader.columns(runId, "state") == @["RUNNING"]

      writeFile(deckFile.changeFileExt("release"), "")
      check daemon.request(%*{"id": 9, "cmd": "shutdown"}) == %*{"id": 9, "ok": true}
      let remaining = daemon.events & daemon.readRemaining()
      check remaining.len > 0
      check remaining.allIt(it["event"].getStr() == "changed")
      check daemon.process.waitForExit(5_000) == 0
      check $remaining[^1]["revision"].getInt() ==
        reader.getValue(sql"SELECT max(revision) FROM runs")
      check reader.columns(runId, "state, succeeded") == @["FINISHED", "1"]

    test "a reused database keeps its history; each daemon adds a session and continues numbering":
      let
        deckFile = deck("done-restart.dck")
        databaseOption = "--database:" & (testDirectory / "restart.sqlite3")
      for launch in 1..2:
        checkpoint("launch " & $launch)
        let daemon = startDaemon(trnrunOption, databaseOption)
        defer: daemon.closeDaemon()
        let ready = daemon.request(%*{"cmd": "ready"})
        check ready["sessionId"].getInt() == launch
        # A done run's saves: submission, launch, seven events, and its finish.
        check ready["revision"].getInt() == (if launch == 1: 0 else: 10)
        check ready["logId"].getInt() == (if launch == 1: 0 else: 3)
        let reader = daemon.openReader()
        defer: reader.close()
        let runId = daemon.add(deckFile)
        check runId == launch
        reader.waitForState(runId, "FINISHED")
        check reader.columns(runId, "session_id") == @[$launch]
        check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
        check daemon.process.waitForExit(5_000) == 0

    test "refuses a database of another schema version with exit code 1":
      let path = testDirectory / "old-schema.sqlite3"
      block:
        let old = db_sqlite.open(path, "", "", "")
        defer: old.close()
        old.exec(sql"CREATE TABLE runs (run_id TEXT PRIMARY KEY)")
        old.exec(sql"PRAGMA user_version = 2")
      let command =
        runCommand(daemonExecutable, [trnrunOption, "--database:" & path], testDirectory)
      check command.exitCode == 1
      check command.output == ""
      check command.error.contains("schema version 2")
      check command.error.contains("Use a new database file")
      check not fileExists(path & ".lock")

    test "graceful shutdown waits for running runs and cancels queued ones":
      let
        deckFile = deck("gate-shutdown.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      let active = daemon.add(deckFile)
      let queued = daemon.add(deckFile)
      check reader.columns(active, "state") == @["RUNNING"]
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      reader.waitForState(queued, "FINISHED")
      check reader.columns(queued, "trnrun_status, error, succeeded") ==
        @["CANCELLED", "Not started: the daemon shut down", "0"]
      check daemon.request(%*{"cmd": "add", "deckFile": deckFile}) ==
        %*{"ok": false, "error": "The daemon is shutting down"}
      check daemon.request(%*{"cmd": "ready"})["ok"].getBool()
      writeFile(deckFile.changeFileExt("release"), "")
      check daemon.process.waitForExit(5_000) == 0
      check reader.columns(active, "state, succeeded") == @["FINISHED", "1"]

    test "shutdown with cancelRunning kills running TRNRun and exits":
      let
        deckFile = deck("gate-cancel-running.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:2")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      let first = daemon.add(deckFile)
      let second = daemon.add(deckFile)
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.request(%*{"cmd": "cancel", "runId": first}) == %*{"ok": true}
      reader.waitForState(first, "FINISHED")
      check daemon.request(%*{"cmd": "shutdown", "cancelRunning": true}) == %*{"ok": true}
      check daemon.process.waitForExit(5_000) == 0
      check reader.columns(first, "error") == @["Interrupted: cancelled by the client"]
      check reader.columns(second, "trnrun_status, error, exit_code IS NULL") ==
        @["CANCELLED", "Interrupted: the daemon shut down", "1"]
      check not fileExists(deckFile.changeFileExt("released"))

    test "closing stdin during a graceful shutdown exits at once":
      let
        deckFile = deck("gate-impatient.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      let runId = daemon.add(deckFile)
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      daemon.process.inputStream.close()
      check daemon.process.waitForExit(5_000) == 0
      check reader.columns(runId, "state, error") ==
        @["FINISHED", "Interrupted: the client disconnected"]

    test "cancel kills one running TRNRun and cancels one queued run, leaving the others":
      let
        cancelledDeck = deck("gate-cancel.dck")
        keptDeck = deck("done-cancel.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      let
        running = daemon.add(cancelledDeck)
        queued = daemon.add(keptDeck)
        kept = daemon.add(keptDeck)
      check reader.columns(running, "state") == @["RUNNING"]

      check daemon.request(%*{"cmd": "cancel", "runId": queued}) == %*{"ok": true}
      check reader.columns(queued, "state, error, started_at IS NULL") ==
        @["FINISHED", "Not started: cancelled by the client", "1"]
      check daemon.request(%*{"cmd": "cancel", "runId": running}) == %*{"ok": true}
      reader.waitForState(running, "FINISHED")
      check reader.columns(running, "trnrun_status, error, exit_code IS NULL, succeeded") ==
        @["CANCELLED", "Interrupted: cancelled by the client", "1", "0"]
      reader.waitForState(kept, "FINISHED")
      check reader.columns(kept, "succeeded") == @["1"]

      check daemon.request(%*{"cmd": "cancel", "runId": kept}) == %*{"ok": true}
      check reader.columns(kept, "succeeded") == @["1"]
      check daemon.request(%*{"cmd": "cancel", "runId": 99}) ==
        %*{"ok": false, "error": "Unknown runId: 99"}
      writeFile(cancelledDeck.changeFileExt("release"), "")
      sleep(300)
      check not fileExists(cancelledDeck.changeFileExt("released"))
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.process.waitForExit(5_000) == 0

    test "EOF exits immediately, killing running TRNRun and saving it as interrupted":
      let
        deckFile = deck("gate-orphan.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      let run = daemon.add(deckFile)
      let queued = daemon.add(deckFile)
      check reader.columns(queued, "state") == @["QUEUED"]
      daemon.process.inputStream.close()
      check daemon.readRemaining().allIt("event" in it) # stdout ends with the daemon.
      check daemon.process.waitForExit(5_000) == 0
      check reader.columns(run, "state, exit_code IS NULL, error") ==
        @["FINISHED", "1", "Interrupted: the client disconnected"]
      check reader.columns(queued, "state, error") ==
        @["FINISHED", "Not started: the client disconnected"]
      writeFile(deckFile.changeFileExt("release"), "")
      sleep(300)
      check not fileExists(deckFile.changeFileExt("released"))

    test "a client that stops reading stdout holds up neither saving nor the exit on EOF":
      let
        doneDeck = deck("done-unread.dck")
        gateDeck = deck("gate-unread.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:2")
      defer: daemon.closeDaemon()
      let reader = daemon.openReader()
      defer: reader.close()
      let gated = daemon.add(gateDeck)
      for _ in 1..200: # Unread replies, far more than the pipe holds.
        daemon.send($(%*{"cmd": "ready"}))
      daemon.send($(%*{"cmd": "add", "deckFile": doneDeck}))
      reader.waitFor(gated + 1, "state = 'FINISHED' AND succeeded")
      let started = getMonoTime()
      daemon.process.inputStream.close()
      check daemon.process.waitForExit(5_000) == 0
      check getMonoTime() - started < initDuration(seconds = 3)
      check reader.columns(gated, "state, error") ==
        @["FINISHED", "Interrupted: the client disconnected"]

    test "a second daemon cannot use a database another one holds":
      let
        path = testDirectory / "shared.sqlite3"
        first = startDaemon(trnrunOption, "--database:" & path)
      defer: first.closeDaemon()
      let reader = first.openReader() # The database is open from here.
      defer: reader.close()
      let owned = first.add(deck("done-owned.dck"))
      reader.waitForState(owned, "FINISHED")
      let before = reader.columns(owned, "*")
      let second = runCommand(daemonExecutable, [trnrunOption, "--database:" & path], testDirectory)
      check second.exitCode == 1
      check second.output == ""
      check second.error.contains("Database is in use by another trnrund")
      check fileExists(path & ".lock")
      check reader.columns(owned, "*") == before

      check first.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check first.process.waitForExit(5_000) == 0
      let third = startDaemon(trnrunOption, "--database:" & path)
      defer: third.closeDaemon()
      check third.request(%*{"cmd": "ready"})["ok"].getBool()

    test "the next daemon finishes a killed one's runs as interrupted, without running them":
      let
        deckFile = deck("gate-killed.dck")
        queuedDeck = deck("done-killed.dck")
        databaseOption = "--database:" & (testDirectory / "killed.sqlite3")
        killed = startDaemon(trnrunOption, "--maxConcurrent:1", databaseOption)
      defer: killed.closeDaemon()
      let reader = killed.openReader()
      defer: reader.close()
      let run = killed.add(deckFile)
      let queued = killed.add(queuedDeck)
      killed.process.kill() # No chance to save anything: the run stays RUNNING.
      discard killed.process.waitForExit(5_000)
      check reader.columns(run, "state, finished_at IS NULL") == @["RUNNING", "1"]
      check reader.columns(queued, "state") == @["QUEUED"]

      let next = startDaemon(trnrunOption, databaseOption)
      defer: next.closeDaemon()
      check next.request(%*{"cmd": "ready"})["sessionId"].getInt() == 2
      check reader.columns(run, "state, trnrun_status, error") ==
        @["FINISHED", "CANCELLED", "Interrupted: its daemon stopped unexpectedly"]
      check reader.columns(queued, "state, error, started_at IS NULL") ==
        @["FINISHED", "Not started: its daemon stopped unexpectedly", "1"]
      check next.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check next.process.waitForExit(5_000) == 0

    test "database failures are fatal rather than error replies":
      let
        deckFile = deck("done-fatal.dck")
        daemon = startDaemon(trnrunOption)
      defer: daemon.closeDaemon()
      let path = daemon.request(%*{"cmd": "ready"})["databasePath"].getStr()
      let injector = db_sqlite.open(path, "", "", "")
      injector.exec(sql"""CREATE TRIGGER fail_submission BEFORE INSERT ON runs
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
      injector.close()
      daemon.send($(%*{"cmd": "add", "deckFile": deckFile}))
      check daemon.process.waitForExit(5_000) == 1
      check daemon.process.outputStream.readAll() == ""
      check daemon.process.errorStream.readAll().contains("injected failure")
      let reader = db_sqlite.open(path, "", "", "")
      defer: reader.close()
      reader.exec(sql"PRAGMA query_only = ON")
      check reader.getValue(sql"SELECT count(*) FROM runs") == "0"

runTests()
