import std/[json, os, osproc, streams, strutils, unittest]

import ../src/outputsink
import ../src/trnrun


const
  Timestamp = "2026-08-30T12:00:00"
  HeldPipeLine = "inherited stdout remained open"


type CommandResult = object
  stdout: string
  stderr: string
  exitCode: int


proc runnerArguments(): seq[string] =
  result = @[]
  if paramCount() >= 2:
    for index in 2 .. paramCount():
      result.add(paramStr(index))

proc fakeRunID(): string =
  for argument in runnerArguments():
    if argument.startsWith("--runID:"):
      return argument[8 .. ^1]
  result = ""

proc runFakeRunner(deckFile: string) =
  let
    mode = deckFile.splitFile().name.toLowerAscii()
    runID = fakeRunID()
  case mode
  of "protocol":
    stdout.writeLine($(%*{
      "kind": "STATUS",
      "timestamp": Timestamp,
      "status": "RUNNING",
      "runID": runID,
    }))
    stdout.writeLine($(%*{
      "kind": "FUTURE_EVENT",
      "runID": runID,
      "arguments": runnerArguments(),
    }))
    stdout.flushFile()
    quit(0)

  of "routing":
    stdout.writeLine("raw stderr or stdout")
    stdout.writeLine("{not valid JSON}")
    stdout.writeLine("[]")
    stdout.writeLine($(%*{"runID": runID}))
    stdout.writeLine($(%*{"kind": 1, "runID": runID}))
    stdout.writeLine($(%*{"kind": "STATUS", "runID": 1}))
    stdout.writeLine($(%*{"kind": "STATUS", "runID": "another-run"}))
    stdout.flushFile()
    quit(0)
  of "fail":
    stderr.writeLine("native crash")
    stderr.flushFile()
    quit(2)
  of "inherited":
    let holder = startProcess(
      getAppFilename(),
      args = ["--hold-stdout"],
      options = {poParentStreams, poDaemon},
    )
    holder.close()
    stdout.writeLine("runner exited")
    stdout.flushFile()
    quit(0)
  else:
    quit(0)

proc invokeRunTrnrun() =
  if paramCount() < 4:
    quit("Expected deck, runner, and run ID", 2)

  var runnerArgs: seq[string] = @[]
  if paramCount() >= 5:
    for index in 5 .. paramCount():
      runnerArgs.add(paramStr(index))

  var output = default(OutputSink)
  output.initOutputSink()
  try:
    discard runTrnrun(
      paramStr(2),
      paramStr(3),
      paramStr(4),
      runnerArgs,
      output,
    )
  finally:
    output.deinitOutputSink()

if paramCount() >= 1:
  if paramStr(1) == "--invoke-runtrnrun":
    invokeRunTrnrun()
    quit(0)
  elif paramStr(1) == "--hold-stdout":
    sleep(500)
    stdout.writeLine(HeldPipeLine)
    stdout.flushFile()
    quit(0)
  elif paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
    runFakeRunner(paramStr(1))


proc runCommand(arguments: openArray[string]): CommandResult =
  result = default(CommandResult)
  let process = startProcess(
    getAppFilename(),
    args = arguments,
    options = {},
  )
  try:
    result.exitCode = process.waitForExit()
    result.stdout = process.outputStream.readAll()
    result.stderr = process.errorStream.readAll()
  finally:
    process.close()

proc invokeRun(
    deckFile: string,
    runnerPath: string,
    runID: string,
    runnerArgs: openArray[string] = [],
): CommandResult =
  result = runCommand(
    @["--invoke-runtrnrun", deckFile, runnerPath, runID] & @runnerArgs,
  )

proc nonEmptyLines(content: string): seq[string] =
  result = @[]
  for line in content.splitLines():
    if line.len > 0:
      result.add(line)

proc errorEvent(command: CommandResult): JsonNode =
  checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
  check command.exitCode == 0
  check command.stderr.len == 0
  let lines = command.stdout.nonEmptyLines()
  check lines.len == 1
  if lines.len != 1:
    return newJNull()
  result = parseJson(lines[0])

proc checkErrorEvent(event: JsonNode, runID: string) =
  check event.kind == JObject
  check event["kind"].getStr() == "STATUS"
  check event["status"].getStr() == "ERROR"
  check event["runID"].getStr() == runID
  check event["seq"].getInt() == 1
  check event["timestamp"].getStr().len == 19
  check event["message"].getStr().len > 0

proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake deck")

proc runTests() =
  let
    testDirectory = getTempDir() /
      ("trnrunq_trnrun_tests_" & $getCurrentProcessId())
    executable = getAppFilename()

  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  try:
    suite "TRNRun process runner":
      test "forwards routed protocol objects unchanged including unknown kinds":
        let
          deckFile = createDeck(testDirectory, "protocol.dck")
          command = invokeRun(
            deckFile,
            executable,
            "forwarded-run",
            ["--fake-option", "value with spaces"],
          )
          lines = command.stdout.nonEmptyLines()

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check lines.len == 2
        if lines.len == 2:
          check lines[0] == $(%*{
            "kind": "STATUS",
            "timestamp": Timestamp,
            "status": "RUNNING",
            "runID": "forwarded-run",
          })
          check lines[1] == $(%*{
            "kind": "FUTURE_EVENT",
            "runID": "forwarded-run",
            "arguments": @[
              "--fake-option",
              "value with spaces",
              "--runID:forwarded-run",
            ],
          })


      test "forwards every merged child line unchanged":
        let
          deckFile = createDeck(testDirectory, "routing.dck")
          command = invokeRun(deckFile, executable, "routing-run")
          lines = command.stdout.nonEmptyLines()
          originalLines = [
            "raw stderr or stdout",
            "{not valid JSON}",
            "[]",
            $(%*{"runID": "routing-run"}),
            $(%*{"kind": 1, "runID": "routing-run"}),
            $(%*{"kind": "STATUS", "runID": 1}),
            $(%*{"kind": "STATUS", "runID": "another-run"}),
          ]

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check lines == @originalLines

      test "allows a runner to exit zero without output":
        let
          deckFile = createDeck(testDirectory, "silent.dck")
          command = invokeRun(deckFile, executable, "silent-run")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stdout.len == 0
        check command.stderr.len == 0

      test "forwards output from a nonzero child crash":
        let
          deckFile = createDeck(testDirectory, "fail.dck")
          command = invokeRun(deckFile, executable, "failed-run")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check command.stdout.nonEmptyLines() == @["native crash"]

      test "emits STATUS ERROR when runner path validation fails":
        let
          deckFile = createDeck(testDirectory, "valid.dck")
          missingRunner = testDirectory / "missing-runner.exe"
          event = invokeRun(deckFile, missingRunner, "missing-runner").errorEvent()

        event.checkErrorEvent("missing-runner")
        check event["message"].getStr().contains("TRNRun not found:")

      test "emits STATUS ERROR when the validated runner cannot launch":
        let
          deckFile = createDeck(testDirectory, "launch.dck")
          invalidRunner = testDirectory / "invalid-runner.exe"

        writeFile(invalidRunner, "not a Windows executable")
        let event = invokeRun(
          deckFile,
          invalidRunner,
          "launch-failure",
        ).errorEvent()

        event.checkErrorEvent("launch-failure")
        check not event["message"].getStr().contains("TRNRun not found:")

      test "returns when a descendant keeps runner stdout open":
        let
          deckFile = createDeck(testDirectory, "inherited.dck")
          command = invokeRun(deckFile, executable, "inherited-stdout")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check command.stdout.nonEmptyLines() == @["runner exited"]
        check not command.stdout.contains(HeldPipeLine)
  finally:
    if dirExists(testDirectory):
      removeDir(testDirectory)

runTests()
