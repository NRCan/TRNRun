import std/[json, monotimes, os, osproc, streams, strutils, times, unittest]

import ../src/request
import ../src/workerpool


const
  Timestamp = "2026-08-30T12:00:00"
  HeldPipeLine = "inherited stdout remained open"


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
  of "cancelled":
    let holder = startProcess(
      getAppFilename(),
      args = ["--hold-stdout"],
      options = {poParentStreams, poDaemon},
    )
    holder.close()
    stdout.writeLine($(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "CANCELLED",
      "message": "",
      "seq": 1,
      "runId": runId,
    }))
    stdout.flushFile()
    quit(130)
  of "fail":
    stderr.writeLine("fake native crash diagnostic")
    quit(2)
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

proc runPoolFromArguments() =
  let
    maxConcurrent = parseInt(paramStr(2))
    maxPending = parseInt(paramStr(3))
  var pool = default(WorkerPool)
  try:
    pool.start(maxConcurrent, maxPending)
    let submissionStartedAt = getMonoTime()
    if paramCount() >= 4:
      for index in 4 .. paramCount():
        pool.submit(parseRequest(paramStr(index)))
    if maxPending > 0:
      stderr.writeLine(
        "submitMilliseconds=" &
        $((getMonoTime() - submissionStartedAt).inMilliseconds),
      )
      stderr.flushFile()
  finally:
    pool.shutdown()

if paramCount() >= 1:
  if paramStr(1) == "--hold-stdout":
    sleep(500)
    stdout.writeLine(HeldPipeLine)
    stdout.flushFile()
    quit(0)
  elif paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
    runFakeRunner(paramStr(1))
  elif paramStr(1) == "--run-pool":
    runPoolFromArguments()
    quit(0)


type CommandResult = object
  stdout: string
  stderr: string
  exitCode: int

proc runCommand(
    executable: string,
    arguments: openArray[string],
    workingDirectory: string,
): CommandResult =
  result = default(CommandResult)
  let process = startProcess(
    executable,
    workingDir = workingDirectory,
    args = arguments,
    options = {},
  )
  try:
    result.exitCode = process.waitForExit()
    result.stdout = process.outputStream.readAll()
    result.stderr = process.errorStream.readAll()
  finally:
    process.close()

proc requestLine(runId, deckFile, runnerPath: string): string =
  $(%*{
    "runId": runId,
    "deckFile": deckFile,
    "runnerPath": runnerPath,
  })

proc runPoolCommand(
    executable: string,
    workingDirectory: string,
    maxConcurrent: int,
    requests: openArray[string],
    maxPending: int = 0,
): CommandResult =
  var arguments = @["--run-pool", $maxConcurrent, $maxPending]
  for request in requests:
    arguments.add(request)
  executable.runCommand(arguments, workingDirectory)

proc parseJsonMessages(content: string): seq[JsonNode] =
  result = @[]
  for line in content.splitLines():
    if line.len > 0:
      try:
        result.add(parseJson(line))
      except JsonParsingError:
        discard

proc nonEmptyLines(content: string): seq[string] =
  result = @[]
  for line in content.splitLines():
    if line.len > 0:
      result.add(line)

proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake deck")

proc runTests() =
  let
    testDirectory = getTempDir() / "trnrunq_workerpool_tests"
    executable = getAppFilename()

  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  try:
    suite "worker pool":
      test "rejects invalid limits before starting":
        var pool = default(WorkerPool)

        expect ValueError:
          pool.start(maxConcurrent = 0)
        expect ValueError:
          pool.start(maxConcurrent = 1, maxPending = -1)

        pool.shutdown()

      test "shutdown drains queued work":
        let
          deckFile = createDeck(testDirectory, "slow.dck")
          command = runPoolCommand(
            executable,
            testDirectory,
            1,
            [
              requestLine("queued-1", deckFile, executable),
              requestLine("queued-2", deckFile, executable),
              requestLine("queued-3", deckFile, executable),
            ],
          )
          events = command.stdout.parseJsonMessages()

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check events.len == 6
        for runId in ["queued-1", "queued-2", "queued-3"]:
          var statuses: seq[string] = @[]
          for event in events:
            if event["runId"].getStr() == runId:
              statuses.add(event["status"].getStr())
          check statuses == @["RUNNING", "DONE"]

      test "never exceeds maximum concurrency":
        let
          deckFile = createDeck(testDirectory, "slow.dck")
          command = runPoolCommand(
            executable,
            testDirectory,
            2,
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
        check command.stderr.len == 0
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

      test "blocks submission while the pending queue is full":
        let
          deckFile = createDeck(testDirectory, "slow.dck")
          command = runPoolCommand(
            executable,
            testDirectory,
            1,
            [
              requestLine("bounded-1", deckFile, executable),
              requestLine("bounded-2", deckFile, executable),
              requestLine("bounded-3", deckFile, executable),
            ],
            maxPending = 1,
          )
          events = command.stdout.parseJsonMessages()
          timingParts = command.stderr.strip().split('=')

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check events.len == 6
        check timingParts.len == 2
        if timingParts.len == 2:
          check timingParts[0] == "submitMilliseconds"
          check parseInt(timingParts[1]) >= 250

      test "accepts duplicate submissions":
        let
          deckFile = createDeck(testDirectory, "duplicate.dck")
          duplicate = requestLine("duplicate", deckFile, executable)
          command = runPoolCommand(
            executable,
            testDirectory,
            2,
            [duplicate, duplicate],
          )
          events = command.stdout.parseJsonMessages()

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check events.len == 4

        var
          runningCount = 0
          doneCount = 0
        for event in events:
          check event["runId"].getStr() == "duplicate"
          case event["status"].getStr()
          of "RUNNING":
            inc runningCount
          of "DONE":
            inc doneCount
          else:
            discard
        check runningCount == 2
        check doneCount == 2

      test "continues after a runner exits before stdout closes":
        let
          cancelledDeck = createDeck(testDirectory, "cancelled.dck")
          nextDeck = createDeck(testDirectory, "after-cancelled.dck")
          command = runPoolCommand(
            executable,
            testDirectory,
            1,
            [
              requestLine("cancelled", cancelledDeck, executable),
              requestLine("next", nextDeck, executable),
            ],
          )
          events = command.stdout.parseJsonMessages()

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check not command.stdout.contains(HeldPipeLine)
        check events.len == 3
        check events[0]["runId"].getStr() == "cancelled"
        check events[0]["status"].getStr() == "CANCELLED"
        check events[1]["runId"].getStr() == "next"
        check events[1]["status"].getStr() == "RUNNING"
        check events[2]["runId"].getStr() == "next"
        check events[2]["status"].getStr() == "DONE"

      test "forwards merged and malformed child output unchanged":
        let
          goodDeck = createDeck(testDirectory, "good.dck")
          failingDeck = createDeck(testDirectory, "fail.dck")
          malformedDeck = createDeck(testDirectory, "malformed.dck")
          command = runPoolCommand(
            executable,
            testDirectory,
            1,
            [
              requestLine("good", goodDeck, executable),
              requestLine("failed", failingDeck, executable),
              requestLine("malformed", malformedDeck, executable),
            ],
          )
          outputLines = command.stdout.nonEmptyLines()
          messages = command.stdout.parseJsonMessages()

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check outputLines.len == 6
        check outputLines.contains("fake runner diagnostic")
        check outputLines.contains("fake native crash diagnostic")
        check outputLines.contains("{not valid JSON}")
        check messages.len == 3
        check messages[0]["runId"].getStr() == "good"
        check messages[1]["runId"].getStr() == "good"
        check messages[2]["runId"].getStr() == "malformed"
        for message in messages:
          check message["kind"].getStr() == "STATUS"
          check not message.hasKey("queueSeq")
          check not message.hasKey("type")
  finally:
    if dirExists(testDirectory):
      removeDir(testDirectory)

runTests()
