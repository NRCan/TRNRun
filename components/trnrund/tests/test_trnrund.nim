import std/[json, os, osproc, streams, strutils, unittest]

import ./fake_trnrun


type CommandResult = object
  output: string
  error: string
  exitCode: int

proc runCommand(
    executable: string,
    arguments: openArray[string],
    workingDirectory: string,
): CommandResult =
  result = CommandResult(output: "", error: "", exitCode: -1)
  let process = startProcess(
    executable,
    workingDir = workingDirectory,
    args = arguments,
    options = {},
  )
  defer: process.close()

  result.output = process.outputStream.readAll()
  result.error = process.errorStream.readAll()
  result.exitCode = process.waitForExit()

proc request(daemon: Process, line: string): JsonNode =
  ## Sends one request line and parses the reply line.
  daemon.inputStream.writeLine(line)
  daemon.inputStream.flush()
  parseJson(daemon.outputStream.readLine())

proc request(daemon: Process, request: JsonNode): JsonNode =
  daemon.request($request)

proc waitForState(daemon: Process, runId, state: string): JsonNode =
  ## Polls `snapshot` until `runId` reaches `state`, returning the last reply.
  result = nil
  for _ in 0 ..< 500:
    result = daemon.request(%*{"cmd": "snapshot", "runId": runId})
    if result["simulation"]["state"].getStr() == state:
      return
    sleep(10)

proc runTests() =
  const TestVersion = "daemon-test-version"

  let
    daemonDirectory = currentSourcePath().parentDir().parentDir()
    daemonSource = daemonDirectory / "src" / "trnrund.nim"
    testDirectory = getTempDir() / "trnrund_daemon_cli_tests"
    daemonExecutable = testDirectory / "trnrund-test.exe"
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
          "--out:" & daemonExecutable,
          daemonSource,
        ],
        daemonDirectory,
      )

  suite "daemon CLI build":
    test "compiles the daemon test executable":
      if buildResult.exitCode != 0:
        checkpoint(buildResult.output & buildResult.error)
      check buildResult.exitCode == 0
      check fileExists(daemonExecutable)

  if buildResult.exitCode != 0:
    return

  let trnrunOption = "--trnrun:" & getAppFilename()

  suite "daemon CLI":
    test "prints help and version without a TRNRun executable":
      for option in ["-h", "--help"]:
        checkpoint("help option: " & option)
        let command = runCommand(daemonExecutable, [option], testDirectory)

        check command.exitCode == 0
        check command.output.contains("Usage:")
        check command.output.contains("--maxConcurrent:N")
        check command.output.contains("Exit codes: 0 ok")

      for option in ["-v", "--version"]:
        checkpoint("version option: " & option)
        let command = runCommand(daemonExecutable, [option], testDirectory)

        check command.exitCode == 0
        check command.output.strip() == TestVersion

    test "reports usage errors on stderr only, with exit code 2":
      let cases = [
        (arguments: @["--doesNotExist"], expected: "Unknown option: --doesNotExist"),
        (arguments: @["-x"], expected: "Unknown option: -x"),
        (arguments: @["extra"], expected: "Unexpected argument: extra"),
        (arguments: @["--maxConcurrent:many"], expected: "many"),
        (arguments: @[trnrunOption, "--maxConcurrent:0"],
          expected: "'maxConcurrent' must be at least 1"),
        (arguments: @["--trnrun:missing.exe"], expected: "TRNRun not found:"),
        (arguments: newSeq[string](), expected: "TRNRun not found:"),
      ]

      for testCase in cases:
        checkpoint("arguments: " & testCase.arguments.join(" "))
        let command = runCommand(daemonExecutable, testCase.arguments, testDirectory)

        check command.exitCode == 2
        check command.output == ""
        check command.error.contains(testCase.expected)

    test "serves requests in order until shutdown, then exits 0":
      let
        deckFile = testDirectory / "done.dck"
        daemon = startProcess(
          daemonExecutable, args = [trnrunOption, "--maxConcurrent:2"], options = {}
        )
      defer: daemon.close()
      writeFile(deckFile, "fake TRNSYS deck")

      check daemon.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile}) ==
        %*{"ok": true}
      check not daemon.request("garbage")["ok"].getBool()
      check daemon.waitForState("run", "FINISHED")["simulation"]["succeeded"].getBool()
      check daemon.request(%*{"cmd": "collect", "runId": "run"})["logs"].len == 3
      check daemon.request(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check daemon.waitForExit() == 0

    test "exits at once when the client closes stdin, killing running TRNRun":
      let
        deckFile = testDirectory / "gate-orphan.dck"
        daemon = startProcess(daemonExecutable, args = [trnrunOption], options = {})
      defer: daemon.close()
      writeFile(deckFile, "fake TRNSYS deck")

      check daemon.request(%*{"cmd": "add", "runId": "run", "deckFile": deckFile}) ==
        %*{"ok": true}
      check daemon.waitForState("run", "RUNNING")["simulation"]["state"].getStr() ==
        "RUNNING"

      daemon.inputStream.close()
      check daemon.waitForExit(5_000) == 0
      check not daemon.running

      # A fake TRNRun that survived would see this release and leave a marker.
      writeFile(deckFile.changeFileExt("release"), "")
      sleep(300)
      check not fileExists(deckFile.changeFileExt("released"))

runTests()
