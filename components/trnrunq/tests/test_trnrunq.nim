import std/[os, osproc, streams, strutils, unittest]


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
  try:
    result.output = process.outputStream.readAll() & process.errorStream.readAll()
    result.exitCode = process.waitForExit()
  finally:
    process.close()

proc runTests() =
  const TestVersion = "queue-test-version"

  let
    queueDirectory = currentSourcePath().parentDir().parentDir()
    queueSource = queueDirectory / "src" / "trnrunq.nim"
    testDirectory = getTempDir() / "trnrunq_cli_tests"
    queueExecutable = testDirectory / "trnrunq-test.exe"
    nimCache = testDirectory / "nimcache"

  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  try:
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
            "--threads:on",
            "--nimcache:" & nimCache,
            "-d:NimblePkgVersion=" & TestVersion,
            "--out:" & queueExecutable,
            queueSource,
          ],
          queueDirectory,
        )

    suite "queue CLI build":
      test "compiles the queue test executable":
        if buildResult.exitCode != 0:
          checkpoint(buildResult.output)
        check buildResult.exitCode == 0
        check fileExists(queueExecutable)

    if buildResult.exitCode != 0:
      return

    suite "queue CLI":
      test "prints help for short and long options":
        for option in ["-h", "--help"]:
          checkpoint("help option: " & option)
          let command = runCommand(queueExecutable, [option], testDirectory)

          check command.exitCode == 0
          check command.output.contains("Usage:")
          check command.output.contains("--maxConcurrent:N")
          check command.output.contains("--maxPending:N")
          check command.output.contains("Exit codes: 0 ok")

      test "prints the configured package version":
        for option in ["-v", "--version"]:
          checkpoint("version option: " & option)
          let command = runCommand(queueExecutable, [option], testDirectory)

          check command.exitCode == 0
          check command.output.strip() == TestVersion

      test "rejects invalid arguments":
        let cases = [
          (arguments: @["--doesNotExist:true"], expected: "Unknown queue option"),
          (arguments: @["--maxConcurrent"], expected: "invalid integer"),
          (arguments: @["--maxConcurrent:nope"], expected: "invalid integer"),
          (arguments: @["--maxConcurrent:0"], expected: "must be at least 1"),
          (arguments: @["--maxPending:-1"], expected: "must be at least 0"),
          (arguments: @["unexpected"], expected: "Unexpected positional argument"),
        ]

        for testCase in cases:
          checkpoint("invalid arguments: " & $testCase.arguments)
          let command = runCommand(
            queueExecutable,
            testCase.arguments,
            testDirectory,
          )

          check command.exitCode == 2
          check command.output.contains(testCase.expected)
  finally:
    if dirExists(testDirectory):
      removeDir(testDirectory)

runTests()
