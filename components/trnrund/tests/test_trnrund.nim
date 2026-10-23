import std/[json, monotimes, os, osproc, sequtils, streams, strutils, tempfiles, times, unittest]

import ./[fake_deck, fake_trnrun]

type
  CommandResult = object
    output: string
    error: string
    exitCode: int

  Daemon = ref object
    ## A running trnrund.
    process: Process

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

proc readReply(daemon: Daemon): JsonNode =
  ## The next stdout line, which must be a reply.
  var line = ""
  if not daemon.process.outputStream.readLine(line):
    raise newException(IOError, "trnrund closed its output")
  result = parseJson(line)
  doAssert result.hasKey("ok"), "not a reply: " & line

proc request(daemon: Daemon, request: JsonNode): JsonNode =
  ## Sends `request` and returns its reply.
  daemon.send($request)
  daemon.readReply()

proc add(daemon: Daemon, deckFile: string): int =
  ## Adds a run and returns its runId.
  let reply = daemon.request(%*{"cmd": "add", "deckFile": deckFile})
  doAssert reply["ok"].getBool(), $reply
  reply["runId"].getInt()

proc run(daemon: Daemon, runId: int): JsonNode =
  ## The current state of `runId`.
  let reply = daemon.request(%*{"cmd": "get", "runId": runId})
  doAssert reply["ok"].getBool(), $reply
  reply["run"]

proc waitForState(daemon: Daemon, runId: int, state: string): JsonNode =
  ## Polls until `runId` is in `state` and returns it: the daemon must run while stdin is idle.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while getMonoTime() < deadline:
    result = daemon.run(runId)
    if result["state"].getStr() == state:
      return
    sleep(10)
  raise newException(IOError, "Timed out waiting for run " & $runId & " to be " & state)

proc closeInput(daemon: Daemon): seq[string] =
  ## Closes the daemon's stdin and returns every line it wrote afterwards.
  daemon.process.inputStream.close()
  result = @[]
  var line = ""
  while daemon.process.outputStream.readLine(line):
    result.add(line)

proc closeDaemon(daemon: Daemon) =
  ## Terminates the daemon if it still runs, then closes its process.
  if daemon.process.running:
    daemon.process.terminate()
    discard daemon.process.waitForExit(5_000)
  daemon.process.close()

proc fields(run: JsonNode, names: varargs[string]): seq[JsonNode] =
  ## The values of `names` in `run`.
  names.mapIt(run[it])

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
  proc startDaemon(arguments: varargs[string]): Daemon =
    ## Starts the daemon with `arguments`.
    Daemon(process: startProcess(daemonExecutable, workingDir = testDirectory,
      args = @arguments, options = {}))

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
        check command.output.contains("Commands: ready, add, get, release, cancel, shutdown.")
        check command.output.contains("README.md")
        check command.output.contains("Exit codes: 0 ok")
        check not command.output.contains("database")
      for option in ["-v", "--version"]:
        let command = runCommand(daemonExecutable, [option], testDirectory)
        check command.exitCode == 0
        check command.output.strip() == TestVersion

    test "reports usage errors on stderr only, with exit code 2":
      let cases = [
        (arguments: @["--doesNotExist"], expected: "Unknown option: --doesNotExist"),
        (arguments: @["-x"], expected: "Unknown option: -x"),
        (arguments: @["extra"], expected: "Unexpected argument: extra"),
        (arguments: @["--database:runs.sqlite3"], expected: "Unknown option: --database"),
        (arguments: @["--maxConcurrent:many"], expected: "many"),
        (arguments: @[trnrunOption, "--maxConcurrent:0"],
          expected: "'maxConcurrent' must be at least 1"),
        (arguments: @["--trnrun:missing.exe"], expected: "TRNRun not found:"),
        (arguments: newSeq[string](), expected: "TRNRun not found:"),
      ]
      for testCase in cases:
        checkpoint("arguments: " & testCase.arguments.join(" "))
        let command = runCommand(daemonExecutable, testCase.arguments, testDirectory)
        check command.exitCode == 2
        check command.output == ""
        check command.error.contains(testCase.expected)

    test "serves requests in order, numbers runs, and answers for their state and logs":
      let
        deckFile = deck("done.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:2")
      defer: daemon.closeDaemon()
      check daemon.request(%*{"id": "r1", "cmd": "ready"}) == %*{
        "id": "r1", "ok": true, "protocolVersion": 2, "version": TestVersion, "maxConcurrent": 2,
      }
      let added = daemon.request(%*{"id": 2, "cmd": "add", "deckFile": deckFile, "label": "first"})
      check (added["id"], added["ok"], added["runId"]) == (%2, %true, %1)

      let run = daemon.waitForState(1, "FINISHED")
      check run.fields("deckFile", "label", "succeeded", "trnrunStatus", "percent", "notices",
        "warnings") == @[%deckFile, %"first", %true, %"DONE", %1.0, %2, %1]
      check run["submittedAt"].getStr() <= run["startedAt"].getStr()
      check run["startedAt"].getStr() <= run["finishedAt"].getStr()
      check run["logs"].elems.mapIt(it["message"].getStr()) == @["first", "second", "third"]

      check not daemon.request(%*{"cmd": "garbage"})["ok"].getBool()
      daemon.send("garbage")
      check not daemon.readReply()["ok"].getBool()
      check daemon.request(%*{"cmd": "pull"}) == %*{"ok": false, "error": "Unknown cmd: pull"}
      check daemon.add(deckFile) == 2
      check daemon.request(%*{"cmd": "release", "runId": 1}) == %*{"ok": true}
      check daemon.request(%*{"cmd": "get", "runId": 1}) ==
        %*{"ok": false, "error": "Unknown runId: 1"}
      check daemon.closeInput().len == 0 # Every reply was read, and nothing else is written.
      check daemon.process.waitForExit(5_000) == 0

    test "get follows progress and logs while the client polls, until the run finishes":
      let
        deckFile = deck("progressgate-polled.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let runId = daemon.add(deckFile)
      let deadline = getMonoTime() + initDuration(seconds = 5)
      while daemon.run(runId)["percent"] != %0.75:
        check getMonoTime() < deadline
        sleep(10)
      writeFile(deckFile.changeFileExt("release"), "")
      var run = daemon.run(runId)
      while run["state"] != %"FINISHED":
        check getMonoTime() < deadline + initDuration(seconds = 5)
        run = daemon.run(runId)
      check run["logs"].elems.mapIt(it["message"].getStr()) == @["first", "second", "third"]
      check run["succeeded"] == %true
      check daemon.closeInput().len == 0
      check daemon.process.waitForExit(5_000) == 0

    test "an add waiting for RUNNING or FINISHED replies then, and later requests are answered meanwhile":
      let
        runningDeck = deck("gate-wait-running.dck")
        finishedDeck = deck("gate-wait-finished.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let running = daemon.request(%*{
        "id": "r", "cmd": "add", "deckFile": runningDeck, "waitFor": "RUNNING"
      })
      check running["id"] == %"r"
      check running["run"]["state"] == %"RUNNING"
      daemon.send($(%*{"id": "f", "cmd": "add", "deckFile": finishedDeck, "waitFor": "FINISHED"}))
      check daemon.request(%*{"id": 3, "cmd": "get", "runId": 1})["id"] == %3 # Not held behind "f".
      writeFile(runningDeck.changeFileExt("release"), "")
      writeFile(finishedDeck.changeFileExt("release"), "")
      let finished = daemon.readReply()
      check (finished["id"], finished["runId"]) == (%"f", %2)
      check finished["run"].fields("state", "succeeded") == @[%"FINISHED", %true]
      check daemon.closeInput().len == 0
      check daemon.process.waitForExit(5_000) == 0

    test "shutdown cancels queued runs, waits for running ones, and keeps answering until stdin closes":
      let
        deckFile = deck("gate-shutdown.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let active = daemon.add(deckFile)
      let queued = daemon.add(deckFile)
      check daemon.run(active)["state"] == %"RUNNING"
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.run(queued).fields("state", "trnrunStatus", "error", "succeeded") ==
        @[%"FINISHED", %"CANCELLED", %"Not started: the daemon shut down", %false]
      check daemon.request(%*{"cmd": "add", "deckFile": deckFile}) ==
        %*{"ok": false, "error": "The daemon is shutting down"}
      writeFile(deckFile.changeFileExt("release"), "")
      check daemon.waitForState(active, "FINISHED")["succeeded"] == %true
      sleep(200)
      check daemon.process.running # Nothing runs, but the client may still collect results.
      check daemon.run(queued)["state"] == %"FINISHED"
      check daemon.closeInput().len == 0
      check daemon.process.waitForExit(5_000) == 0

    test "shutdown with cancelRunning kills running TRNRun":
      let
        deckFile = deck("gate-cancel-running.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:2")
      defer: daemon.closeDaemon()
      let first = daemon.add(deckFile)
      let second = daemon.add(deckFile)
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.request(%*{"cmd": "cancel", "runId": first}) == %*{"ok": true}
      check daemon.waitForState(first, "FINISHED")["error"] ==
        %"Interrupted: cancelled by the client"
      check daemon.request(%*{"cmd": "shutdown", "cancelRunning": true}) == %*{"ok": true}
      check daemon.waitForState(second, "FINISHED").fields("trnrunStatus", "error", "exitCode") ==
        @[%"CANCELLED", %"Interrupted: the daemon shut down", newJNull()]
      check daemon.closeInput().len == 0
      check daemon.process.waitForExit(5_000) == 0
      check not fileExists(deckFile.changeFileExt("released"))

    test "cancel kills one running TRNRun and cancels one queued run, leaving the others":
      let
        cancelledDeck = deck("gate-cancel.dck")
        keptDeck = deck("done-cancel.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      let
        running = daemon.add(cancelledDeck)
        queued = daemon.add(keptDeck)
        kept = daemon.add(keptDeck)
      check daemon.run(running)["state"] == %"RUNNING"

      check daemon.request(%*{"cmd": "cancel", "runId": queued}) == %*{"ok": true}
      check daemon.run(queued).fields("state", "error", "startedAt") ==
        @[%"FINISHED", %"Not started: cancelled by the client", newJNull()]
      check daemon.request(%*{"cmd": "cancel", "runId": running}) == %*{"ok": true}
      check daemon.waitForState(running, "FINISHED").fields(
        "trnrunStatus", "error", "exitCode", "succeeded") ==
        @[%"CANCELLED", %"Interrupted: cancelled by the client", newJNull(), %false]
      check daemon.waitForState(kept, "FINISHED")["succeeded"] == %true

      check daemon.request(%*{"cmd": "cancel", "runId": kept}) == %*{"ok": true}
      check daemon.run(kept)["succeeded"] == %true
      check daemon.request(%*{"cmd": "cancel", "runId": 99}) ==
        %*{"ok": false, "error": "Unknown runId: 99"}
      writeFile(cancelledDeck.changeFileExt("release"), "")
      sleep(300)
      check not fileExists(cancelledDeck.changeFileExt("released"))

    test "EOF exits immediately, killing running TRNRun and dropping waiting adds":
      let
        deckFile = deck("gate-orphan.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:1")
      defer: daemon.closeDaemon()
      discard daemon.add(deckFile)
      let queued = daemon.add(deckFile)
      check daemon.run(queued)["state"] == %"QUEUED"
      daemon.send($(%*{"id": 3, "cmd": "add", "deckFile": deckFile, "waitFor": "FINISHED"}))
      check daemon.closeInput().len == 0 # stdout ends with the daemon, without the late reply.
      check daemon.process.waitForExit(5_000) == 0
      writeFile(deckFile.changeFileExt("release"), "")
      sleep(300)
      check not fileExists(deckFile.changeFileExt("released"))

    test "a client that stops reading stdout holds up neither its runs nor the exit on EOF":
      let
        firstDeck = deck("gate-unread-first.dck")
        secondDeck = deck("gate-unread-second.dck")
        daemon = startDaemon(trnrunOption, "--maxConcurrent:2")
      defer: daemon.closeDaemon()
      discard daemon.add(firstDeck)
      for _ in 1..200: # Unread replies, far more than the pipe holds.
        daemon.send($(%*{"cmd": "ready"}))
      daemon.send($(%*{"cmd": "add", "deckFile": secondDeck}))
      writeFile(secondDeck.changeFileExt("release"), "")
      let deadline = getMonoTime() + initDuration(seconds = 5)
      while not fileExists(secondDeck.changeFileExt("released")): # Launched despite the unread replies.
        check getMonoTime() < deadline
        sleep(10)
      let started = getMonoTime()
      daemon.process.inputStream.close()
      check daemon.process.waitForExit(5_000) == 0
      check getMonoTime() - started < initDuration(seconds = 3)
      writeFile(firstDeck.changeFileExt("release"), "")
      sleep(300)
      check not fileExists(firstDeck.changeFileExt("released"))

runTests()
