import std/[json, os, osproc, streams, strutils, unittest]


const Timestamp = "2026-08-29T12:00:00"

proc runFakeRunner(deckFile: string) =
  let mode = deckFile.splitFile().name.toLowerAscii()
  case mode
  of "fail":
    stderr.writeLine("fake runner validation failure")
    quit(2)
  of "error":
    echo $(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "PENDING",
      "seq": 1,
    })
    echo $(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "ERROR",
      "exitCode": 1,
      "error": {
        "code": "FAKE_ERROR",
        "message": "fake simulation failed",
      },
      "seq": 2,
    })
    quit(1)
  else:
    echo $(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "PENDING",
      "seq": 1,
    })
    echo $(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "RUNNING",
      "seq": 2,
    })
    sleep(25)
    echo $(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "DONE",
      "seq": 3,
    })
    quit(0)

if paramCount() >= 1 and
    paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
  runFakeRunner(paramStr(1))


type CommandResult = object
  stdout: string
  stderr: string
  exitCode: int

proc runCommand(
    executable: string,
    arguments: openArray[string],
    workingDirectory: string,
): CommandResult =
  result = CommandResult(stdout: "", stderr: "", exitCode: -1)
  let process = startProcess(
    executable,
    workingDir = workingDirectory,
    args = arguments,
    options = {},
  )
  defer: process.close()

  # Windows pipe streams can report only currently available bytes while the
  # process is still running. These test commands have bounded output, so reap
  # first and then drain both completed pipes.
  result.exitCode = process.waitForExit()
  result.stdout = process.outputStream.readAll()
  result.stderr = process.errorStream.readAll()

proc parseJsonLines(content: string): seq[JsonNode] =
  result = @[]
  for line in content.splitLines():
    if line.startsWith("{"):
      result.add(line.parseJson())

proc terminalEvents(events: openArray[JsonNode], jobId: string): seq[JsonNode] =
  result = @[]
  for event in events:
    if event["jobId"].getStr() == jobId and
        event["kind"].getStr() == "STATUS" and
        event["status"].getStr() in ["DONE", "CANCELLED", "ERROR", "TIMEOUT", "STALLED"]:
      result.add(event)

proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake deck")

proc runTests() =
  let
    queueDirectory = currentSourcePath().parentDir().parentDir()
    queueSource = queueDirectory / "src" / "trnrunq.nim"
    testDirectory = getTempDir() / "trnrunq_cli_tests"
    queueExecutable = testDirectory / "trnrunq-test.exe"
    nimCache = testDirectory / "nimcache"

  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  let compiler = findExe("nim")
  let buildResult =
    if compiler.len == 0:
      CommandResult(stderr: "Nim compiler was not found on PATH", exitCode: -1)
    else:
      runCommand(
        compiler,
        [
          "c",
          "--hints:off",
          "--verbosity:0",
          "--threads:on",
          "--nimcache:" & nimCache,
          "--out:" & queueExecutable,
          queueSource,
        ],
        queueDirectory,
      )

  suite "trnrunq build":
    test "compiles the queue executable":
      if buildResult.exitCode != 0:
        checkpoint(buildResult.stdout & buildResult.stderr)
      check buildResult.exitCode == 0
      check fileExists(queueExecutable)

  if buildResult.exitCode != 0:
    return

  suite "trnrunq protocol":
    test "routes successful child events as strict JSONL":
      let
        firstDeck = createDeck(testDirectory, "first.dck")
        secondDeck = createDeck(testDirectory, "second.trd")
        command = runCommand(
          queueExecutable,
          [
            firstDeck,
            secondDeck,
            "--runnerPath:" & getAppFilename(),
            "--maxConcurrent:2",
          ],
          testDirectory,
        )
        events = command.stdout.parseJsonLines()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 0
      check events.len == 8
      check command.stdout.strip().splitLines().len == events.len

      for index, event in events:
        check event["queueSeq"].getInt() == index + 1
        check event.hasKey("jobId")
        check event.hasKey("deckFile")

      for jobId in ["1", "2"]:
        let terminal = events.terminalEvents(jobId)
        check terminal.len == 1
        if terminal.len == 1:
          check terminal[0]["status"].getStr() == "DONE"
          check terminal[0]["exitCode"].getInt() == 0
          check terminal[0]["seq"].getInt() == 3

    test "synthesizes an error when a child exits without terminal status":
      let
        deckFile = createDeck(testDirectory, "fail.dck")
        command = runCommand(
          queueExecutable,
          [deckFile, "--runnerPath:" & getAppFilename()],
          testDirectory,
        )
        events = command.stdout.parseJsonLines()
        terminal = events.terminalEvents("1")

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 1
      check terminal.len == 1
      if terminal.len == 1:
        check terminal[0]["status"].getStr() == "ERROR"
        check terminal[0]["exitCode"].getInt() == 2
        check terminal[0]["error"].getStr().contains(
          "trnrun exited without emitting a terminal status"
        )
        check terminal[0]["error"].getStr().contains(
          "fake runner validation failure"
        )

    test "rejects missing and duplicate decks with one terminal event each":
      let
        deckFile = createDeck(testDirectory, "duplicate.dck")
        missingDeck = testDirectory / "missing.dck"
        command = runCommand(
          queueExecutable,
          [
            deckFile,
            deckFile,
            missingDeck,
            "--runnerPath:" & getAppFilename(),
          ],
          testDirectory,
        )
        events = command.stdout.parseJsonLines()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 1
      for jobId in ["1", "2", "3"]:
        check events.terminalEvents(jobId).len == 1
      let
        firstTerminal = events.terminalEvents("1")
        secondTerminal = events.terminalEvents("2")
        thirdTerminal = events.terminalEvents("3")
      if firstTerminal.len == 1:
        check firstTerminal[0]["status"].getStr() == "DONE"
      if secondTerminal.len == 1:
        check secondTerminal[0]["error"].getStr().contains(
          "The same deck cannot run concurrently in one queue"
        )
      if thirdTerminal.len == 1:
        check thirdTerminal[0]["error"].getStr().contains(
          "Deck file does not exist"
        )

    test "reports a missing runner for every otherwise valid job":
      let
        deckFile = createDeck(testDirectory, "runner-missing.dck")
        missingRunner = testDirectory / "missing-trnrun.exe"
        command = runCommand(
          queueExecutable,
          [deckFile, "--runnerPath:" & missingRunner],
          testDirectory,
        )
        terminal = command.stdout.parseJsonLines().terminalEvents("1")

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 1
      check terminal.len == 1
      if terminal.len == 1:
        check terminal[0]["error"].getStr().contains(
          "trnrun executable does not exist"
        )

    test "uses exit code 2 for queue usage errors without writing JSONL":
      let command = runCommand(
        queueExecutable,
        ["--maxConcurrent:0"],
        testDirectory,
      )

      check command.exitCode == 2
      check command.stdout.len == 0
      check command.stderr.contains("--maxConcurrent")

runTests()
