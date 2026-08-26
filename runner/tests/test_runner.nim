import std/[json, os, osproc, streams, strutils, unittest]


if paramCount() >= 1 and
    paramStr(1).splitFile().ext.toLowerAscii() in [".dck", ".trd"]:
  sleep(50)
  quit(QuitSuccess)

type CommandResult = object
  output: string
  exitCode: int

proc runCommand(
    executable: string,
    arguments: openArray[string],
    workingDirectory: string,
): CommandResult =
  result = CommandResult(output: "", exitCode: -1)
  let process = startProcess(
    executable,
    workingDir = workingDirectory,
    args = arguments,
    options = {},
  )
  defer: process.close()

  let standardOutput = process.outputStream.readAll()
  let standardError = process.errorStream.readAll()
  result.output = standardOutput & standardError
  result.exitCode = process.waitForExit()

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)

proc findEvent(output, kind: string): JsonNode =
  result = nil
  for line in output.splitLines():
    if line.startsWith("{"):
      let node = line.parseJson()
      if node{"kind"}.getStr() == kind:
        return node

proc runTests() =
  const TestVersion = "runner-test-version"

  let
    runnerDirectory = currentSourcePath().parentDir().parentDir()
    runnerSource = runnerDirectory / "src" / "runner.nim"
    testDirectory = getTempDir() / "trnrun_runner_cli_tests"
    runnerExecutable = testDirectory / "trnrun-test.exe"
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
      CommandResult(output: "Nim compiler was not found on PATH", exitCode: -1)
    else:
      runCommand(
        compiler,
        [
          "c",
          "--hints:off",
          "--verbosity:0",
          "--nimcache:" & nimCache,
          "-d:NimblePkgVersion=" & TestVersion,
          "--out:" & runnerExecutable,
          runnerSource,
        ],
        runnerDirectory,
      )

  suite "runner CLI build":
    test "compiles the runner test executable":
      if buildResult.exitCode != 0:
        checkpoint(buildResult.output)
      check buildResult.exitCode == 0
      check fileExists(runnerExecutable)

  if buildResult.exitCode != 0:
    return

  suite "runner CLI":
    test "prints help for short and long options":
      for option in ["-h", "--help"]:
        checkpoint("help option: " & option)
        let command = runCommand(
          runnerExecutable,
          [option],
          testDirectory,
        )

        check command.exitCode == 0
        check command.output.contains("Usage:")
        check command.output.contains("--guiVisibility:MODE")
        check command.output.contains("Exit codes: 0 done")

    test "prints the configured package version":
      for option in ["-v", "--version"]:
        checkpoint("version option: " & option)
        let command = runCommand(
          runnerExecutable,
          [option],
          testDirectory,
        )

        check command.exitCode == 0
        check command.output.strip() == TestVersion

    test "rejects unknown options":
      let command = runCommand(
        runnerExecutable,
        ["--doesNotExist:true"],
        testDirectory,
      )

      check command.exitCode == 2
      check command.output.contains("Unknown option: doesNotExist")

    test "rejects a second positional deck argument":
      let command = runCommand(
        runnerExecutable,
        ["first.dck", "second.dck"],
        testDirectory,
      )

      check command.exitCode == 2
      check command.output.contains("Unexpected argument: second.dck")

    test "reports invalid option values through the CLI error boundary":
      let cases = [
        (option: "--guiVisibility:visible", expected: "Invalid guiVisibility: visible"),
        (option: "--watchLog:maybe", expected: "Error:"),
        (option: "--pollMs:not-a-number", expected: "Error:"),
        (option: "--severity:Debug", expected: "Error:"),
      ]

      for testCase in cases:
        checkpoint("invalid option: " & testCase.option)
        let command = runCommand(
          runnerExecutable,
          [testCase.option],
          testDirectory,
        )

        check command.exitCode == 2
        check command.output.contains(testCase.expected)

    test "accepts every documented GUI visibility spelling":
      let missingDeck = testDirectory / "missing.dck"
      for mode in [
        "keep",
        "keepopen",
        "auto",
        "autoclose",
        "min",
        "minimized",
        "minauto",
        "minimizedauto",
        "hidden",
      ]:
        checkpoint("GUI visibility: " & mode)
        let command = runCommand(
          runnerExecutable,
          [missingDeck, "--guiVisibility:" & mode],
          testDirectory,
        )

        check command.exitCode == 2
        check command.output.contains("Deck file not found:")
        check not command.output.contains("Invalid guiVisibility")

    test "accepts all documented setting options":
      let missingDeck = testDirectory / "all-options-missing.dck"
      let command = runCommand(
        runnerExecutable,
        [
          "--deckFile:" & missingDeck,
          "--trnexePath:C:\\TRNSYS18\\Exe\\TrnEXE64.exe",
          "--guiVisibility:minimizedauto",
          "--waitForGui:false",
          "--waitForLst:false",
          "--waitForTmp:true",
          "--detectTimeout:1234",
          "--extraDelay:25",
          "--watchLog:false",
          "--watchTmp:true",
          "--watchTimeout:5000",
          "--stallTimeout:3000",
          "--pollMs:50",
          "--clean:true",
          "--killOnTimeout:true",
          "--killOnStall:true",
          "--severity:Warning",
          "--writeEvents:true",
        ],
        testDirectory,
      )

      check command.exitCode == 2
      check command.output.contains("Deck file not found:")
      check not command.output.contains("Unknown option:")

    test "maps every CLI setting to the emitted SETTING event":
      let deckFile = testDirectory / "semantic-settings.dck"
      writeFile(deckFile, "test")

      let command = runCommand(
        runnerExecutable,
        [
          deckFile,
          "--trnexePath:" & getAppFilename(),
          "--guiVisibility:hidden",
          "--waitForGui:false",
          "--waitForLst:false",
          "--waitForTmp:false",
          "--detectTimeout:1234",
          "--extraDelay:25",
          "--watchLog:false",
          "--watchTmp:false",
          "--watchTimeout:5000",
          "--stallTimeout:3000",
          "--pollMs:50",
          "--clean:true",
          "--killOnTimeout:true",
          "--killOnStall:true",
          "--severity:Warning",
          "--writeEvents:false",
        ],
        testDirectory,
      )

      check command.exitCode == 0
      let setting = command.output.findEvent("SETTING")
      check setting != nil
      check setting["trnexePath"].getStr() ==
        getAppFilename().absolutePath().normalizedPath()
      check setting["guiVisibility"].getStr() == "hidden"
      check not setting["waitForGui"].getBool()
      check not setting["waitForLst"].getBool()
      check not setting["waitForTmp"].getBool()
      check setting["detectTimeoutMs"].getInt() == 1234
      check setting["extraDelayMs"].getInt() == 25
      check not setting["watchLog"].getBool()
      check not setting["watchTmp"].getBool()
      check setting["watchTimeoutMs"].getInt() == 5000
      check setting["stallTimeoutMs"].getInt() == 3000
      check setting["pollMs"].getInt() == 50
      check setting["cleanOnSuccess"].getBool()
      check setting["killOnTimeout"].getBool()
      check setting["killOnStall"].getBool()
      check setting["severity"].getStr() == "Warning"
      check not setting["writeEvents"].getBool()

    test "reports missing and unsupported deck files":
      let
        missingDeck = testDirectory / "missing-deck.dck"
        unsupportedDeck = testDirectory / "existing-deck.txt"
      writeFile(unsupportedDeck, "test")

      let missingCommand = runCommand(
        runnerExecutable,
        [missingDeck],
        testDirectory,
      )
      let unsupportedCommand = runCommand(
        runnerExecutable,
        [unsupportedDeck],
        testDirectory,
      )

      check missingCommand.exitCode == 2
      check missingCommand.output.contains("Deck file not found:")
      check unsupportedCommand.exitCode == 2
      check unsupportedCommand.output.contains("Expected .dck or .trd")

    test "does not create an event file when logging is disabled":
      let
        deckFile = testDirectory / "logging-disabled.dck"
        eventFile = deckFile.changeFileExt("jsonl")
        missingTrnexe = testDirectory / "missing-TrnEXE64.exe"
      writeFile(deckFile, "test")
      removeIfExists(eventFile)

      let command = runCommand(
        runnerExecutable,
        [deckFile, "--trnexePath:" & missingTrnexe],
        testDirectory,
      )

      check command.exitCode == 2
      check command.output.contains("TRNEXE not found:")
      check not fileExists(eventFile)

    test "creates and closes the event file when logging is enabled":
      let
        deckFile = testDirectory / "logging-enabled.dck"
        eventFile = deckFile.changeFileExt("jsonl")
        missingTrnexe = testDirectory / "missing-TrnEXE64.exe"
      writeFile(deckFile, "test")
      removeIfExists(eventFile)

      let command = runCommand(
        runnerExecutable,
        [
          deckFile,
          "--trnexePath:" & missingTrnexe,
          "--writeEvents:true",
        ],
        testDirectory,
      )

      check command.exitCode == 2
      check command.output.contains("TRNEXE not found:")
      check fileExists(eventFile)
      check readFile(eventFile) == ""

      removeFile(eventFile)
      check not fileExists(eventFile)

runTests()
