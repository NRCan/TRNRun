import std/[algorithm, json, os, osproc, streams, strutils, unittest]

import ../src/request
import ../src/workerpool


const
  Timestamp = "2026-08-30T12:00:00"
  HeldPipeLine = "inherited stdout remained open"


proc fakeRunID(): string =
  result = ""
  if paramCount() >= 2:
    for index in 2 .. paramCount():
      let argument = paramStr(index)
      if argument.startsWith("--runID:"):
        return argument[8 .. ^1]

proc runFakeRunner(deckFile: string) =
  let
    mode = deckFile.splitFile().name.toLowerAscii()
    runID = fakeRunID()
  case mode
  of "silent":
    quit(0)
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
      "runID": runID,
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
      "runID": runID,
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
      "runID": runID,
    }))
    stdout.flushFile()
    if mode == "slow":
      sleep(500)
    if mode == "good":
      stderr.writeLine("fake runner diagnostic")
      stderr.flushFile()
    stdout.writeLine($(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "DONE",
      "message": "",
      "seq": 2,
      "runID": runID,
    }))
    stdout.flushFile()
    quit(0)

proc runPoolFromArguments() =
  let maxConcurrent = parseInt(paramStr(2))
  var pool = default(WorkerPool)
  try:
    pool.start(maxConcurrent)
    if paramCount() >= 3:
      for index in 3 .. paramCount():
        pool.submit(parseRequest(paramStr(index)))
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

proc requestLine(runID, deckFile, runnerPath: string): string =
  $(%*{
    "runID": runID,
    "deckFile": deckFile,
    "runnerPath": runnerPath,
  })

proc runPoolCommand(
    executable: string,
    workingDirectory: string,
    maxConcurrent: int,
    requests: openArray[string],
): CommandResult =
  var arguments = @["--run-pool", $maxConcurrent]
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

proc messagesOfKind(messages: openArray[JsonNode], kind: string): seq[JsonNode] =
  result = @[]
  for message in messages:
    if message.kind == JObject and message.hasKey("kind") and
        message["kind"].kind == JString and message["kind"].getStr() == kind:
      result.add(message)

proc queueEvents(
    messages: openArray[JsonNode],
    eventName: string,
): seq[JsonNode] =
  result = @[]
  for message in messages.messagesOfKind("QUEUE"):
    if message.hasKey("event") and message["event"].kind == JString and
        message["event"].getStr() == eventName:
      result.add(message)

proc acceptedRunIDs(messages: openArray[JsonNode]): seq[string] =
  result = @[]
  for message in messages.queueEvents("ACCEPTED"):
    result.add(message["runID"].getStr())

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
      test "rejects invalid concurrency before starting":
        var pool = default(WorkerPool)

        expect ValueError:
          pool.start(maxConcurrent = 0)
        expect ValueError:
          pool.start(maxConcurrent = -1)

        pool.shutdown()

      test "enforces the single-use lifecycle":
        var pool = default(WorkerPool)

        pool.shutdown()
        expect ValueError:
          pool.submit(default(RunRequest))

        pool.start(maxConcurrent = 1)
        pool.shutdown()
        pool.shutdown()

        expect ValueError:
          pool.submit(default(RunRequest))
        expect ValueError:
          pool.start(maxConcurrent = 1)

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
          messages = command.stdout.parseJsonMessages()
          events = messages.messagesOfKind("STATUS")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check messages.acceptedRunIDs() == @["queued-1", "queued-2", "queued-3"]
        check messages.queueEvents("COMPLETED").len == 3
        check events.len == 6
        for runID in ["queued-1", "queued-2", "queued-3"]:
          var statuses: seq[string] = @[]
          for event in events:
            if event["runID"].getStr() == runID:
              statuses.add(event["status"].getStr())
          check statuses == @["RUNNING", "DONE"]

      test "stops more workers than the one-slot channel can hold":
        let command = runPoolCommand(
          executable,
          testDirectory,
          3,
          [],
        )

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stdout.len == 0
        check command.stderr.len == 0

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
          messages = command.stdout.parseJsonMessages()
          events = messages.messagesOfKind("STATUS")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check messages.acceptedRunIDs().sorted() ==
          @["slow-1", "slow-2", "slow-3", "slow-4"]
        check messages.queueEvents("COMPLETED").len == 4
        check events.len == 8

        var
          active = 0
          maxActive = 0
        for event in messages.messagesOfKind("QUEUE"):
          case event["event"].getStr()
          of "ACCEPTED":
            inc active
            maxActive = max(maxActive, active)
          of "COMPLETED":
            dec active
          else:
            check false
          check active >= 0
          check active <= 2
        check active == 0
        check maxActive == 2

      test "does not accept the next request while the worker is busy":
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
          )
          messages = command.stdout.parseJsonMessages()
          events = messages.messagesOfKind("STATUS")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check events.len == 6

        var lifecycle: seq[string] = @[]
        for event in messages.messagesOfKind("QUEUE"):
          lifecycle.add(event["runID"].getStr() & ":" & event["event"].getStr())
        check lifecycle == @[
          "bounded-1:ACCEPTED", "bounded-1:COMPLETED",
          "bounded-2:ACCEPTED", "bounded-2:COMPLETED",
          "bounded-3:ACCEPTED", "bounded-3:COMPLETED",
        ]


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
          messages = command.stdout.parseJsonMessages()
          events = messages.messagesOfKind("STATUS")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check not command.stdout.contains(HeldPipeLine)
        check messages.acceptedRunIDs() == @["cancelled", "next"]
        check events.len == 3
        check events[0]["runID"].getStr() == "cancelled"
        check events[0]["status"].getStr() == "CANCELLED"
        check events[1]["runID"].getStr() == "next"
        check events[1]["status"].getStr() == "RUNNING"
        check events[2]["runID"].getStr() == "next"
        check events[2]["status"].getStr() == "DONE"

      test "preserves child output order and completes after output":
        let deckFile = createDeck(testDirectory, "ordering.dck")
        var requests: seq[string] = @[]
        for index in 1 .. 4:
          requests.add(requestLine("ordering-" & $index, deckFile, executable))

        let
          command = runPoolCommand(
            executable,
            testDirectory,
            4,
            requests,
          )
          lines = command.stdout.nonEmptyLines()
          messages = command.stdout.parseJsonMessages()
          completed = messages.queueEvents("COMPLETED")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check messages.len == lines.len
        check messages.acceptedRunIDs().len == requests.len
        check completed.len == requests.len

        for index in 1 .. 4:
          let runID = "ordering-" & $index
          var
            acceptedIndex = -1
            completedIndex = -1
            outputIndices: seq[int] = @[]
          for messageIndex, message in messages:
            if message["runID"].getStr() != runID:
              continue
            if message["kind"].getStr() == "QUEUE" and
                message["event"].getStr() == "ACCEPTED":
              acceptedIndex = messageIndex
            elif message["kind"].getStr() == "QUEUE" and
                message["event"].getStr() == "COMPLETED":
              completedIndex = messageIndex
            else:
              outputIndices.add(messageIndex)

          check acceptedIndex >= 0
          check completedIndex > acceptedIndex
          check outputIndices.len == 2
          for outputIndex in outputIndices:
            check acceptedIndex < outputIndex
            check outputIndex < completedIndex

      test "accepts before fast runner resolution errors with multiple workers":
        let
          deckFile = createDeck(testDirectory, "admission.dck")
          missingRunner = testDirectory / "missing-runner.exe"
        var
          requests: seq[string] = @[]
          runIDs: seq[string] = @[]
        # Keep batches small: runCommand waits for exit before draining stdout.
        for index in 1 .. 6:
          let runID = "admission-" & $index
          runIDs.add(runID)
          requests.add(requestLine(runID, deckFile, missingRunner))

        let
          command = runPoolCommand(executable, testDirectory, 4, requests)
          messages = command.stdout.parseJsonMessages()

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check messages.len == command.stdout.nonEmptyLines().len
        check messages.len == requests.len * 3
        check messages.acceptedRunIDs().sorted() == runIDs

        for runID in runIDs:
          var runMessages: seq[JsonNode] = @[]
          for message in messages:
            if message["runID"].getStr() == runID:
              runMessages.add(message)

          require runMessages.len == 3
          require runMessages[0]["kind"].getStr() == "QUEUE"
          check runMessages[0]["event"].getStr() == "ACCEPTED"
          require runMessages[1]["kind"].getStr() == "STATUS"
          check runMessages[1]["status"].getStr() == "ERROR"
          check runMessages[1]["message"].getStr().contains("TRNRun not found:")
          require runMessages[2]["kind"].getStr() == "QUEUE"
          check runMessages[2]["event"].getStr() == "COMPLETED"
          check runMessages[2]["exitCode"].kind == JNull

      test "reports completion metadata for exit and launch paths":
        let
          silentDeck = createDeck(testDirectory, "silent.dck")
          failingDeck = createDeck(testDirectory, "fail.dck")
          missingRunner = testDirectory / "missing-runner.exe"
          command = runPoolCommand(
            executable,
            testDirectory,
            1,
            [
              requestLine("silent", silentDeck, executable),
              requestLine("crash", failingDeck, executable),
              requestLine("invalid", silentDeck, missingRunner),
            ],
          )
          lines = command.stdout.nonEmptyLines()
          messages = command.stdout.parseJsonMessages()
          completed = messages.queueEvents("COMPLETED")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check command.stdout.contains("fake native crash diagnostic")
        check messages.len + 1 == lines.len
        check completed.len == 3

        for event in completed:
          case event["runID"].getStr()
          of "silent":
            check event["exitCode"].kind == JInt
            check event["exitCode"].getInt() == 0
          of "crash":
            check event["exitCode"].kind == JInt
            check event["exitCode"].getInt() == 2
          of "invalid":
            check event["exitCode"].kind == JNull
          else:
            check false

        for event in completed:
          let runID = event["runID"].getStr()
          var completedIndex = -1
          for index, message in messages:
            if message == event:
              completedIndex = index
            elif message["runID"].getStr() == runID:
              check completedIndex < 0


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
          events = messages.messagesOfKind("STATUS")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check outputLines.len == 12
        check messages.len == 9
        check messages.acceptedRunIDs() == @["good", "failed", "malformed"]
        check messages.queueEvents("COMPLETED").len == 3
        check outputLines.contains("fake runner diagnostic")
        check outputLines.contains("fake native crash diagnostic")
        check outputLines.contains("{not valid JSON}")
        check events.len == 3
        check events[0]["runID"].getStr() == "good"
        check events[1]["runID"].getStr() == "good"
        check events[2]["runID"].getStr() == "malformed"
        for message in events:
          check message["kind"].getStr() == "STATUS"
          check not message.hasKey("queueSeq")
          check not message.hasKey("type")
  finally:
    if dirExists(testDirectory):
      removeDir(testDirectory)

runTests()
