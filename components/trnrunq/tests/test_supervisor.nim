import std/[json, os, osproc, streams, strutils, unittest]

import ../src/supervisor
import ../src/trnrun


const Timestamp = "2026-08-30T12:00:00"


proc fakeRunId(): string =
  result = ""
  if paramCount() >= 2:
    for index in 2 .. paramCount():
      let argument = paramStr(index)
      if argument.startsWith("--runId:"):
        return argument[8 .. ^1]

proc runFakeRunner(deckFile: string) =
  let
    mode = deckFile.splitFile().name.toLowerAscii()
    runId = fakeRunId()
  case mode
  of "fail":
    stderr.writeLine("fake native crash diagnostic")
    quit(2)
  of "minusone":
    quit(-1)
  of "malformed":
    stdout.writeLine("{not valid JSON}")
    stdout.writeLine($(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "DONE",
      "message": "",
      "seq": 1,
      "runId": runId,
    }))
    stdout.flushFile()
    quit(0)
  else:
    stdout.writeLine($(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "RUNNING",
      "message": "",
      "seq": 1,
      "runId": runId,
    }))
    stdout.flushFile()
    if mode == "slow":
      sleep(500)
    stderr.writeLine("fake runner diagnostic")
    stdout.writeLine($(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "DONE",
      "message": "",
      "seq": 2,
      "runId": runId,
    }))
    stdout.flushFile()
    quit(0)

if paramCount() >= 1:
  if paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
    runFakeRunner(paramStr(1))
  elif paramStr(1) == "--serve":
    serve(maxConcurrent = 2)
    quit(0)


type CommandResult = object
  stdout: string
  stderr: string
  exitCode: int

proc runCommand(
    executable: string,
    arguments: openArray[string],
    workingDirectory: string,
    inputLines: openArray[string],
): CommandResult =
  result = default(CommandResult)
  let process = startProcess(
    executable,
    workingDir = workingDirectory,
    args = arguments,
    options = {},
  )
  defer:
    process.close()

  let input = process.inputStream
  for line in inputLines:
    input.writeLine(line)
  input.flush()
  input.close()

  # ponytail: Fake runners emit bounded output; add concurrent pipe readers
  # before introducing high-volume cases.
  result.exitCode = process.waitForExit()
  result.stdout = process.outputStream.readAll()
  result.stderr = process.errorStream.readAll()

proc parseJsonMessages(content: string): seq[JsonNode] =
  result = @[]
  for line in content.splitLines():
    if line.len > 0:
      try:
        result.add(parseJson(line))
      except JsonParsingError:
        discard

proc readEvent(stream: Stream, runId: string): JsonNode =
  var line = ""
  while stream.readLine(line):
    try:
      let event = parseJson(line)
      if event.kind == JObject and event.hasKey("runId") and
          event["runId"].kind == JString and event["runId"].getStr() == runId:
        return event
    except JsonParsingError:
      discard
  raise newException(IOError, "Queue stdout closed before run '" & runId & "' emitted an event")

proc nonEmptyLines(content: string): seq[string] =
  result = @[]
  for line in content.splitLines():
    if line.len > 0:
      result.add(line)

proc requestLine(
    runId: string,
    deckFile: string,
    runnerPath: string,
    runnerArgs: seq[string] = @[],
): string =
  var request = %*{
    "runId": runId,
    "deckFile": deckFile,
    "runnerPath": runnerPath,
  }
  if runnerArgs.len > 0:
    request["runnerArgs"] = newJArray()
    for argument in runnerArgs:
      request["runnerArgs"].add(%argument)
  $request

proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake deck")

proc runTests() =
  let
    testDirectory = getTempDir() / "trnrunq_supervisor_tests"
    executable = getAppFilename()

  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "queue supervision":
    test "validates deck and runner paths":
      let
        deckFile = createDeck(testDirectory, "validated.TRD")
        invalidDeck = createDeck(testDirectory, "invalid.txt")

      check validateDeck(deckFile) == deckFile.absolutePath().normalizedPath()
      check validateTrnrun(executable) == executable.normalizedPath()

      expect ValueError:
        discard validateDeck(invalidDeck)
      expect IOError:
        discard validateDeck(testDirectory / "missing.dck")
      expect IOError:
        discard validateTrnrun(testDirectory / "missing-trnrun.exe")

    test "forwards merged child output unchanged":
      let
        goodDeck = createDeck(testDirectory, "good.dck")
        failingDeck = createDeck(testDirectory, "fail.dck")
        command = runCommand(
          executable,
          ["--serve"],
          testDirectory,
          [
            requestLine(
              "good-run",
              goodDeck,
              executable,
              @["--fake-option"],
            ),
            requestLine("failed-run", failingDeck, executable),
          ],
        )
        outputLines = command.stdout.nonEmptyLines()
        messages = command.stdout.parseJsonMessages()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 0
      check command.stderr.len == 0
      check outputLines.len == 4
      check outputLines.contains("fake runner diagnostic")
      check outputLines.contains("fake native crash diagnostic")
      check messages.len == 2

      for message in messages:
        check message["runId"].getStr() == "good-run"
        check message["kind"].getStr() == "STATUS"
        check not message.hasKey("queueSeq")
        check not message.hasKey("type")

    test "allows a process to exit without output":
      let
        deckFile = createDeck(testDirectory, "minusone.dck")
        command = runCommand(
          executable,
          ["--serve"],
          testDirectory,
          [requestLine("silent-run", deckFile, executable)],
        )

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 0
      check command.stdout.len == 0
      check command.stderr.len == 0

    test "accepts requests until stdin closes":
      let
        firstDeck = createDeck(testDirectory, "incremental-first.dck")
        missingDeck = testDirectory / "missing.dck"
        secondDeck = createDeck(testDirectory, "incremental-second.dck")
        process = startProcess(
          executable,
          workingDir = testDirectory,
          args = ["--serve"],
          options = {},
        )
      defer:
        if process.running:
          process.kill()
        process.close()

      let input = process.inputStream
      input.writeLine(requestLine("incremental-first", firstDeck, executable))
      input.flush()
      check process.outputStream.readEvent("incremental-first")["kind"].getStr() == "STATUS"
      check process.running

      input.writeLine(requestLine("missing", missingDeck, executable))
      input.flush()
      let errorEvent = process.outputStream.readEvent("missing")
      check errorEvent["kind"].getStr() == "STATUS"
      check errorEvent["status"].getStr() == "ERROR"
      check errorEvent["message"].getStr().contains("Deck file not found:")
      check errorEvent["seq"].getInt() == 1
      check errorEvent["timestamp"].getStr().len > 0
      check process.running

      input.writeLine(requestLine("incremental-second", secondDeck, executable))
      input.flush()
      check process.outputStream.readEvent("incremental-second")["kind"].getStr() == "STATUS"
      check process.running

      input.close()
      discard process.outputStream.readAll()
      check process.waitForExit() == 0
      check process.errorStream.readAll().len == 0

    test "limits concurrent runners":
      let
        deckFile = createDeck(testDirectory, "slow.dck")
        command = runCommand(
          executable,
          ["--serve"],
          testDirectory,
          [
            requestLine("slow-1", deckFile, executable),
            requestLine("slow-2", deckFile, executable),
            requestLine("slow-3", deckFile, executable),
            requestLine("slow-4", deckFile, executable),
          ],
        )
        events = command.stdout.parseJsonMessages()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 0
      check events.len == 8

      var
        active = 0
        maxActive = 0
      for event in events:
        case event["status"].getStr()
        of "RUNNING":
          inc active
          maxActive = max(maxActive, active)
        of "DONE":
          dec active
        else:
          discard

      check active == 0
      check maxActive == 2

    test "allows duplicate deck submissions":
      let
        deckFile = createDeck(testDirectory, "duplicate.dck")
        command = runCommand(
          executable,
          ["--serve"],
          testDirectory,
          [
            requestLine("duplicate-1", deckFile, executable),
            requestLine("duplicate-2", deckFile, executable),
          ],
        )
        events = command.stdout.parseJsonMessages()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 0
      check command.stderr.len == 0
      check command.stdout.nonEmptyLines().len == 6
      check events.len == 4

      var eventsByRun = [0, 0]
      for event in events:
        let runId = event["runId"].getStr()
        if runId == "duplicate-1":
          inc eventsByRun[0]
        elif runId == "duplicate-2":
          inc eventsByRun[1]
      check eventsByRun == [2, 2]

    test "forwards malformed child output unchanged":
      let
        deckFile = createDeck(testDirectory, "malformed.dck")
        command = runCommand(
          executable,
          ["--serve"],
          testDirectory,
          [requestLine("malformed-output", deckFile, executable)],
        )
        outputLines = command.stdout.nonEmptyLines()
        envelopes = command.stdout.parseJsonMessages()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 0
      check command.stderr.len == 0
      check outputLines.len == 2
      check outputLines.contains("{not valid JSON}")
      check envelopes.len == 1
      check envelopes[0]["kind"].getStr() == "STATUS"
      check envelopes[0]["runId"].getStr() == "malformed-output"

runTests()
