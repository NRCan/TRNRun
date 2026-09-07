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
    if mode == "good":
      stderr.writeLine("fake runner diagnostic")
      stderr.flushFile()
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

proc acceptedRunIds(messages: openArray[JsonNode]): seq[string] =
  result = @[]
  for message in messages.queueEvents("ACCEPTED"):
    result.add(message["runId"].getStr())

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
        check messages.acceptedRunIds() == @["queued-1", "queued-2", "queued-3"]
        check events.len == 6
        for runId in ["queued-1", "queued-2", "queued-3"]:
          var statuses: seq[string] = @[]
          for event in events:
            if event["runId"].getStr() == runId:
              statuses.add(event["status"].getStr())
          check statuses == @["RUNNING", "DONE"]

      test "stops more workers than a bounded queue can hold":
        let command = runPoolCommand(
          executable,
          testDirectory,
          3,
          [],
          maxPending = 1,
        )

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stdout.len == 0
        check command.stderr.startsWith("submitMilliseconds=")

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
        check messages.acceptedRunIds() == @["slow-1", "slow-2", "slow-3", "slow-4"]
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

      test "does not accept while the pending queue is full":
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
          messages = command.stdout.parseJsonMessages()
          events = messages.messagesOfKind("STATUS")
          timingParts = command.stderr.strip().split('=')

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check messages.acceptedRunIds() == @["bounded-1", "bounded-2", "bounded-3"]
        check events.len == 6
        check timingParts.len == 2
        if timingParts.len == 2:
          check timingParts[0] == "submitMilliseconds"
          check parseInt(timingParts[1]) >= 250

        var
          firstCompletedIndex = -1
          thirdAcceptedIndex = -1
        for index, message in messages:
          if message["runId"].getStr() == "bounded-1" and
              message["kind"].getStr() == "QUEUE" and
              message["event"].getStr() == "COMPLETED":
            firstCompletedIndex = index
          elif message["runId"].getStr() == "bounded-3" and
              message["kind"].getStr() == "QUEUE" and
              message["event"].getStr() == "ACCEPTED":
            thirdAcceptedIndex = index
        check firstCompletedIndex >= 0
        check thirdAcceptedIndex > firstCompletedIndex


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
        check messages.acceptedRunIds() == @["cancelled", "next"]
        check events.len == 3
        check events[0]["runId"].getStr() == "cancelled"
        check events[0]["status"].getStr() == "CANCELLED"
        check events[1]["runId"].getStr() == "next"
        check events[1]["status"].getStr() == "RUNNING"
        check events[2]["runId"].getStr() == "next"
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
        check messages.acceptedRunIds().len == requests.len
        check completed.len == requests.len

        for index in 1 .. 4:
          let runId = "ordering-" & $index
          var
            acceptedIndex = -1
            completedIndex = -1
            outputIndices: seq[int] = @[]
          for messageIndex, message in messages:
            if message["runId"].getStr() != runId:
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
          check completedIndex >= 0
          check outputIndices.len == 2
          for outputIndex in outputIndices:
            check outputIndex < completedIndex

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
          case event["runId"].getStr()
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
          let runId = event["runId"].getStr()
          var completedIndex = -1
          for index, message in messages:
            if message == event:
              completedIndex = index
            elif message["runId"].getStr() == runId:
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
        check messages.acceptedRunIds() == @["good", "failed", "malformed"]
        check messages.queueEvents("COMPLETED").len == 3
        check outputLines.contains("fake runner diagnostic")
        check outputLines.contains("fake native crash diagnostic")
        check outputLines.contains("{not valid JSON}")
        check events.len == 3
        check events[0]["runId"].getStr() == "good"
        check events[1]["runId"].getStr() == "good"
        check events[2]["runId"].getStr() == "malformed"
        for message in events:
          check message["kind"].getStr() == "STATUS"
          check not message.hasKey("queueSeq")
          check not message.hasKey("type")
  finally:
    if dirExists(testDirectory):
      removeDir(testDirectory)

runTests()
