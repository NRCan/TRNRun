import std/[json, os, osproc, streams, strutils, unittest]

import ../src/outputsink
import ../src/trnrun


const HeldPipeLine = "inherited stdout remained open"


type CommandResult = object
  stdout: string
  stderr: string
  exitCode: int


proc runnerArguments(): seq[string] =
  result = @[]
  if paramCount() >= 2:
    for index in 2 .. paramCount():
      result.add(paramStr(index))

proc runFakeRunner(deckFile: string) =
  case deckFile.splitFile().name.toLowerAscii()
  of "forward":
    stdout.writeLine("stdout line with trailing spaces  ")
    stdout.flushFile()
    stderr.writeLine("stderr line")
    stderr.flushFile()
    stdout.writeLine("arguments: " & runnerArguments().join(" | "))
    stdout.flushFile()
    quit(0)
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
    runTrnrun(
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
    runId: string,
    runnerArgs: openArray[string] = [],
): CommandResult =
  result = runCommand(
    @["--invoke-runtrnrun", deckFile, runnerPath, runId] & @runnerArgs,
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

proc checkErrorEvent(event: JsonNode, runId: string) =
  check event.kind == JObject
  check event["kind"].getStr() == "STATUS"
  check event["status"].getStr() == "ERROR"
  check event["runId"].getStr() == runId
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
      test "validates deck paths and extensions":
        let
          dckFile = createDeck(testDirectory, "model.dck")
          trdFile = createDeck(testDirectory, "model.TRD")
          invalidDeck = createDeck(testDirectory, "model.txt")

        check validateDeck(dckFile) == dckFile.absolutePath().normalizedPath()
        check validateDeck(trdFile) == trdFile.absolutePath().normalizedPath()
        expect ValueError:
          discard validateDeck(invalidDeck)
        expect IOError:
          discard validateDeck(testDirectory / "missing.dck")

      test "validates absolute and executable-relative runner paths":
        let executableName = executable.extractFilename()

        check validateTrnrun(executable) == executable.normalizedPath()
        check validateTrnrun(executableName) ==
          (getAppDir() / executableName).normalizedPath()
        expect IOError:
          discard validateTrnrun("missing-trnrun.exe")

      test "forwards merged child output and arguments unchanged":
        let
          deckFile = createDeck(testDirectory, "forward.dck")
          command = invokeRun(
            deckFile,
            executable,
            "forwarded-run",
            ["--fake-option", "value with spaces"],
          )

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stderr.len == 0
        check command.stdout.nonEmptyLines() == @[
          "stdout line with trailing spaces  ",
          "stderr line",
          "arguments: --fake-option | value with spaces | --runId:forwarded-run",
        ]

      test "allows a runner to exit without output":
        let
          deckFile = createDeck(testDirectory, "silent.dck")
          command = invokeRun(deckFile, executable, "silent-run")

        checkpoint("stdout:\n" & command.stdout & "\nstderr:\n" & command.stderr)
        check command.exitCode == 0
        check command.stdout.len == 0
        check command.stderr.len == 0

      test "emits STATUS ERROR for validation failures":
        let
          validDeck = createDeck(testDirectory, "valid.dck")
          invalidDeck = createDeck(testDirectory, "invalid.txt")
          missingDeck = testDirectory / "missing.dck"
          missingRunner = testDirectory / "missing-runner.exe"
          failures = [
            (invokeRun(missingDeck, executable, "missing-deck"), "missing-deck", "Deck file not found:"),
            (invokeRun(invalidDeck, executable, "invalid-deck"), "invalid-deck", "Expected .dck or .trd"),
            (invokeRun(validDeck, missingRunner, "missing-runner"), "missing-runner", "TRNRun not found:"),
          ]

        for (command, runId, expectedMessage) in failures:
          let event = command.errorEvent()
          event.checkErrorEvent(runId)
          check event["message"].getStr().contains(expectedMessage)

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
