import std/[json, os, osproc, streams, strutils, unittest]

import ../src/supervisor


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
  if mode == "cancelled":
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
  if paramStr(1) == "--hold-stdout":
    sleep(500)
    stdout.writeLine(HeldPipeLine)
    stdout.flushFile()
    quit(0)
  elif paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
    runFakeRunner(paramStr(1))
  elif paramStr(1) == "--serve":
    serve(maxConcurrent = 2)
    quit(0)
  elif paramStr(1) == "--serve-one":
    serve(maxConcurrent = 1)
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
  try:
    let input = process.inputStream
    for line in inputLines:
      input.writeLine(line)
    input.flush()
    input.close()

    result.exitCode = process.waitForExit()
    result.stdout = process.outputStream.readAll()
    result.stderr = process.errorStream.readAll()
  finally:
    process.close()

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

proc acceptedRunIds(messages: openArray[JsonNode]): seq[string] =
  result = @[]
  for message in messages.messagesOfKind("QUEUE"):
    if message.hasKey("event") and message["event"].kind == JString and
        message["event"].getStr() == "ACCEPTED":
      result.add(message["runId"].getStr())

proc readStatusEvent(stream: Stream, runId: string, observed: var seq[string]): JsonNode =
  var line = ""
  while stream.readLine(line):
    observed.add(line)
    try:
      let event = parseJson(line)
      if event.kind == JObject and event.hasKey("kind") and
          event["kind"].kind == JString and event["kind"].getStr() == "STATUS" and
          event.hasKey("runId") and event["runId"].kind == JString and
          event["runId"].getStr() == runId:
        return event
    except JsonParsingError:
      discard
  raise newException(IOError, "Queue stdout closed before run '" & runId & "' emitted a status event")

proc requestLine(runId, deckFile, runnerPath: string): string =
  $(%*{
    "runId": runId,
    "deckFile": deckFile,
    "runnerPath": runnerPath,
  })

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
  try:
    suite "queue supervision":
      test "rejects invalid concurrency before starting":
        expect ValueError:
          serve(maxConcurrent = 0)
        expect ValueError:
          serve(maxConcurrent = -1)

      test "accepts incremental input until EOF and drains accepted work":
        let
          firstDeck = createDeck(testDirectory, "incremental-first.dck")
          secondDeck = createDeck(testDirectory, "slow.dck")
          process = startProcess(
            executable,
            workingDir = testDirectory,
            args = ["--serve"],
            options = {},
          )
        try:
          let input = process.inputStream
          var observed: seq[string] = @[]

          input.writeLine(requestLine("incremental-first", firstDeck, executable))
          input.flush()
          check process.outputStream.readStatusEvent("incremental-first", observed)["status"].getStr() ==
            "RUNNING"
          check process.running

          input.writeLine("")
          input.writeLine(requestLine("incremental-second", secondDeck, executable))
          input.flush()
          check process.outputStream.readStatusEvent("incremental-second", observed)["status"].getStr() ==
            "RUNNING"
          check process.running

          input.close()
          observed.add(process.outputStream.readAll().splitLines())
          check process.waitForExit() == 0
          check process.errorStream.readAll().len == 0

          let
            messages = observed.join("\n").parseJsonMessages()
            events = messages.messagesOfKind("STATUS")
          var doneRuns: seq[string] = @[]
          for event in events:
            if event["status"].getStr() == "DONE":
              doneRuns.add(event["runId"].getStr())
          check messages.acceptedRunIds() == @["incremental-first", "incremental-second"]
          check doneRuns.contains("incremental-first")
          check doneRuns.contains("incremental-second")
        finally:
          if process.running:
            process.kill()
          process.close()

      test "drains accepted work and cleans up after an input parse failure":
        let
          deckFile = createDeck(testDirectory, "cancelled.dck")
          command = runCommand(
            executable,
            ["--serve-one"],
            testDirectory,
            [
              requestLine("accepted-before-error", deckFile, executable),
              "{not valid JSON}",
            ],
          )
          messages = command.stdout.parseJsonMessages()
          events = messages.messagesOfKind("STATUS")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode != 0
        check command.stderr.len > 0
        check not command.stdout.contains(HeldPipeLine)
        check messages.acceptedRunIds() == @["accepted-before-error"]
        check events.len == 1
        check events[0]["runId"].getStr() == "accepted-before-error"
        check events[0]["status"].getStr() == "CANCELLED"
  finally:
    if dirExists(testDirectory):
      removeDir(testDirectory)

runTests()
