import std/[json, os, osproc, streams, strutils, unittest]

import protocol
import supervisor
import trnrun


const Timestamp = "2026-08-30T12:00:00"


proc runFakeRunner(deckFile: string) =
  let mode = deckFile.splitFile().name.toLowerAscii()
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
    }))
    stderr.writeLine("fake runner diagnostic")
    stdout.writeLine($(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "DONE",
      "message": "",
      "seq": 2,
    }))
    stdout.flushFile()
    quit(0)

proc runSupervisor(missingRunner: bool = false) =
  let runnerPath =
    if missingRunner: getAppDir() / "missing-trnrun.exe"
    else: getAppFilename()

  var requests: seq[RunRequest] = @[]
  for index in 2 .. paramCount():
    requests.add(RunRequest(
      runId: index - 1,
      deckFile: paramStr(index),
      runnerPath: runnerPath,
    ))

  let summary = superviseRuns(requests, maxConcurrent = 2)
  quit(if summary.failed == 0: 0 else: 1)

if paramCount() >= 1:
  if paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
    runFakeRunner(paramStr(1))
  elif paramStr(1) == "--supervise":
    runSupervisor()
  elif paramStr(1) == "--supervise-missing":
    runSupervisor(missingRunner = true)


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
  defer:
    process.close()

  result.exitCode = process.waitForExit()
  result.stdout = process.outputStream.readAll()
  result.stderr = process.errorStream.readAll()


proc parseJsonLines(content: string): seq[JsonNode] =
  result = @[]
  for line in content.splitLines():
    if line.len > 0:
      result.add(parseJson(line))

proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake deck")

proc runTests() =
  suite "trnrunq3 protocol":
    test "adds routing metadata to runner events":
      let event = routeEvent(7, "  {\"kind\":\"STATUS\",\"seq\":3}  ")
      check event["kind"].getStr() == "STATUS"
      check event["seq"].getInt() == 3
      check event["runId"].getInt() == 7
      check not event.hasKey("type")

      expect JsonParsingError:
        discard routeEvent(7, "{not valid JSON}")
      expect JsonParsingError:
        discard routeEvent(7, "plain output")
      for line in ["[]", "null", "42", "\"text\""]:
        expect ValueError:
          discard routeEvent(7, line)

      let completion = exitEnvelope(7, message = "queue failure")
      check completion["type"].getStr() == "exit"
      check completion["runId"].getInt() == 7
      check completion["message"].getStr() == "queue failure"

    test "rejects duplicate run identifiers before starting work":
      let duplicateRequests = [
        RunRequest(runId: 1, deckFile: "first.dck"),
        RunRequest(runId: 1, deckFile: "second.dck"),
      ]
      expect ValueError:
        discard superviseRuns(duplicateRequests, maxConcurrent = 1)

  let
    testDirectory = getTempDir() / "trnrunq3_tests"
    executable = getAppFilename()

  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "trnrunq3 supervision":
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

    test "forwards runner events and redirects diagnostics":
      let
        goodDeck = createDeck(testDirectory, "good.dck")
        failingDeck = createDeck(testDirectory, "fail.dck")
        command = runCommand(
          executable,
          ["--supervise", goodDeck, failingDeck],
          testDirectory,
        )
        messages = command.stdout.parseJsonLines()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 1
      check messages.len == 4
      check command.stderr.contains("fake runner diagnostic")
      check command.stderr.contains("fake native crash diagnostic")

      var
        lastGoodEvent = -1
        goodExit = -1
        failExit = -1

      for index, message in messages:
        check message.hasKey("runId")
        check not message.hasKey("queueSeq")

        if message.hasKey("kind"):
          check message["runId"].getInt() == 1
          check message["kind"].getStr() == "STATUS"
          lastGoodEvent = index
        else:
          check message["type"].getStr() == "exit"
          if message["runId"].getInt() == 1:
            check not message.hasKey("message")
            goodExit = index
          elif message["runId"].getInt() == 2:
            check message["message"].getStr().contains(
              "exited without producing an event"
            )
            failExit = index

      check lastGoodEvent >= 0
      check goodExit > lastGoodEvent
      check failExit >= 0

    test "reports an error when a process exits without an event":
      let
        deckFile = createDeck(testDirectory, "minusone.dck")
        command = runCommand(
          executable,
          ["--supervise", deckFile],
          testDirectory,
        )
        envelopes = command.stdout.parseJsonLines()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 1
      check envelopes.len == 1
      check envelopes[0]["type"].getStr() == "exit"
      check not envelopes[0].hasKey("exitCode")
      check envelopes[0]["message"].getStr().contains(
        "exited without producing an event"
      )

    test "rejects duplicate deck paths without starting them twice":
      let
        deckFile = createDeck(testDirectory, "duplicate.dck")
        command = runCommand(
          executable,
          ["--supervise", deckFile, deckFile],
          testDirectory,
        )
        envelopes = command.stdout.parseJsonLines()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 1
      check envelopes.len == 4

      var duplicateExit: JsonNode = nil
      for envelope in envelopes:
        if envelope.hasKey("type") and
            envelope["type"].getStr() == "exit" and
            envelope["runId"].getInt() == 2:
          duplicateExit = envelope
      check duplicateExit != nil
      if duplicateExit != nil:
        check not duplicateExit.hasKey("exitCode")
        check duplicateExit["message"].getStr().contains(
          "same deck cannot run concurrently"
        )

    test "reports spawn failures as explicit exits":
      let
        deckFile = createDeck(testDirectory, "spawn-failure.dck")
        command = runCommand(
          executable,
          ["--supervise-missing", deckFile],
          testDirectory,
        )
        envelopes = command.stdout.parseJsonLines()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 1
      check envelopes.len == 1
      check envelopes[0]["type"].getStr() == "exit"
      check not envelopes[0].hasKey("exitCode")
      check envelopes[0]["message"].getStr().contains("TRNRun not found")
      check not envelopes[0].hasKey("queueSeq")


    test "redirects malformed child output to stderr":
      let
        deckFile = createDeck(testDirectory, "malformed.dck")
        command = runCommand(
          executable,
          ["--supervise", deckFile],
          testDirectory,
        )
        envelopes = command.stdout.parseJsonLines()

      checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
      check command.exitCode == 0
      check command.stderr.contains("{not valid JSON}")
      check envelopes.len == 2
      check envelopes[0]["kind"].getStr() == "STATUS"
      check envelopes[0]["runId"].getInt() == 1
      check envelopes[1]["type"].getStr() == "exit"
      check envelopes[1]["runId"].getInt() == 1

runTests()
