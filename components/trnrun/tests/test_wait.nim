import std/unittest

include ../src/wait


const ChildMode = "--wait-test-child"

if paramCount() >= 2 and paramStr(1) == ChildMode:
  case paramStr(2)
  of "sleep":
    sleep(parseInt(paramStr(3)))

  of "write":
    let
      path = paramStr(3)
      delayMs = parseInt(paramStr(4))
      holdMs = parseInt(paramStr(5))
    sleep(delayMs)
    writeFile(path, paramStr(6))
    sleep(holdMs)

  of "ready":
    let
      deckFile = paramStr(3)
      lstDelayMs = parseInt(paramStr(4))
      tmpDelayMs = parseInt(paramStr(5))
      holdMs = parseInt(paramStr(6))
    sleep(lstDelayMs)
    writeFile(deckFile.changeFileExt("lst"), LstHeader & "\n")
    sleep(tmpDelayMs)
    writeFile(deckFile.changeFileExt("tmp"), "0, 0, 100, 1")
    sleep(holdMs)

  else:
    discard

  quit(QuitSuccess)

proc startSleepChild(lifetimeMs: int): Process =
  startProcess(
    getAppFilename(),
    args = [ChildMode, "sleep", $lifetimeMs],
    options = {},
  )

proc startWriteChild(
    path: string,
    content: string,
    delayMs: int,
    holdMs: int = 0,
): Process =
  startProcess(
    getAppFilename(),
    args = [ChildMode, "write", path, $delayMs, $holdMs, content],
    options = {},
  )

proc startReadyChild(
    deckFile: string,
    lstDelayMs: int,
    tmpDelayMs: int,
    holdMs: int,
): Process =
  startProcess(
    getAppFilename(),
    args = [
      ChildMode,
      "ready",
      deckFile,
      $lstDelayMs,
      $tmpDelayMs,
      $holdMs,
    ],
    options = {},
  )

proc stopAndClose(process: Process) =
  if process.running:
    process.terminate()
    discard process.waitForExit()
  process.close()

proc alwaysTrue(): bool {.gcsafe.} =
  true

proc alwaysFalse(): bool {.gcsafe.} =
  false

proc fileExistsCondition(path: string): PollCondition =
  result = proc(): bool {.gcsafe.} =
    fileExists(path)

proc pollErrorMessage(
    initialIntervalMs: int,
    maxIntervalMs: int,
    backoff: float,
    timeoutMs: int,
): string =
  result = ""
  try:
    discard poll(
      nil,
      alwaysTrue,
      timeoutMs,
      initialIntervalMs,
      maxIntervalMs,
      backoff,
    )
  except ValueError as error:
    result = error.msg

proc removeIfExists(path: string) =
  if fileExists(path):
    removeFile(path)


proc runTests() =
  let testDirectory = getTempDir() / "trnrun_wait_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "wait polling":
    test "validates polling parameters":
      check pollErrorMessage(0, 500, 1.3, 100) ==
        "initialIntervalMs must be positive"
      check pollErrorMessage(10, 5, 1.3, 100) ==
        "maxIntervalMs must be >= initialIntervalMs"
      check pollErrorMessage(10, 500, 1.0, 100) ==
        "backoff must be > 1.0"
      check pollErrorMessage(10, 500, 1.3, -1) ==
        "timeoutMs must be >= 0"

    test "returns immediately when the condition is already true":
      check poll(nil, alwaysTrue, 100)

    test "times out without terminating the observed process":
      let process = startSleepChild(500)
      defer: process.stopAndClose()

      check not poll(
        process,
        alwaysFalse,
        timeoutMs = 50,
        initialIntervalMs = 5,
        maxIntervalMs = 10,
      )
      check process.running

    test "performs a final condition check when the process exits":
      let marker = testDirectory / "exit-marker.txt"
      removeIfExists(marker)
      let process = startWriteChild(marker, "ready", 50)
      defer: process.stopAndClose()

      check poll(
        process,
        fileExistsCondition(marker),
        timeoutMs = 1_000,
        initialIntervalMs = 10,
        maxIntervalMs = 20,
      )

    test "returns false when the process exits without satisfying the condition":
      let process = startSleepChild(50)
      defer: process.stopAndClose()

      check not poll(
        process,
        alwaysFalse,
        timeoutMs = 1_000,
        initialIntervalMs = 10,
        maxIntervalMs = 20,
      )

  suite "file readiness":
    test "recognizes only LST files containing the component header":
      let lstFile = testDirectory / "header.lst"
      removeIfExists(lstFile)

      check not checkLst(lstFile)
      writeFile(lstFile, "unrelated output")
      check not checkLst(lstFile)
      writeFile(lstFile, "prefix\n" & LstHeader & "\nsuffix")
      check checkLst(lstFile)

    test "waits for a delayed LST header":
      let
        deckFile = testDirectory / "delayed-lst.dck"
        lstFile = deckFile.changeFileExt("lst")
      removeIfExists(lstFile)
      let process = startWriteChild(lstFile, LstHeader & "\n", 50, 100)
      defer: process.stopAndClose()

      check waitLst(process, deckFile, 500)

    test "waits indefinitely for a delayed TMP file when timeout is zero":
      let
        deckFile = testDirectory / "delayed-tmp.dck"
        tmpFile = deckFile.changeFileExt("tmp")
      removeIfExists(tmpFile)
      let process = startWriteChild(tmpFile, "0, 0, 100, 1", 50, 100)
      defer: process.stopAndClose()

      check waitTmp(process, deckFile, 0)

  suite "readiness orchestration":
    test "returns ready immediately when no conditions are enabled":
      let process = startSleepChild(500)
      defer: process.stopAndClose()

      check waitReady(
        process,
        testDirectory / "no-conditions.dck",
        waitForGui = false,
        waitForLst = false,
        waitForTmp = false,
        timeoutMs = 100,
        extraDelayMs = 0,
      ) == wrReady

    test "returns exited when the process has already stopped":
      let process = startSleepChild(20)
      discard process.waitForExit()
      defer: process.close()

      check waitReady(
        process,
        testDirectory / "already-exited.dck",
        waitForGui = false,
        waitForLst = false,
        waitForTmp = false,
        timeoutMs = 100,
        extraDelayMs = 0,
      ) == wrExited

    test "returns timeout when required output never appears":
      let process = startSleepChild(500)
      defer: process.stopAndClose()

      check waitReady(
        process,
        testDirectory / "missing-output.dck",
        waitForGui = false,
        waitForLst = false,
        waitForTmp = true,
        timeoutMs = 50,
        extraDelayMs = 0,
      ) == wrTimeout
      check process.running

    test "returns exited when the process stops before required output appears":
      let process = startSleepChild(50)
      defer: process.stopAndClose()

      check waitReady(
        process,
        testDirectory / "exited-before-output.dck",
        waitForGui = false,
        waitForLst = false,
        waitForTmp = true,
        timeoutMs = 1_000,
        extraDelayMs = 0,
      ) == wrExited

    test "waits for LST and TMP output in order":
      let deckFile = testDirectory / "ready-files.dck"
      removeIfExists(deckFile.changeFileExt("lst"))
      removeIfExists(deckFile.changeFileExt("tmp"))
      let process = startReadyChild(deckFile, 30, 30, 100)
      defer: process.stopAndClose()

      check waitReady(
        process,
        deckFile,
        waitForGui = false,
        waitForLst = true,
        waitForTmp = true,
        timeoutMs = 500,
        extraDelayMs = 0,
      ) == wrReady

    test "shares one timeout deadline across readiness stages":
      let deckFile = testDirectory / "shared-deadline.dck"
      removeIfExists(deckFile.changeFileExt("lst"))
      removeIfExists(deckFile.changeFileExt("tmp"))
      let process = startReadyChild(deckFile, 60, 80, 100)
      defer: process.stopAndClose()

      check waitReady(
        process,
        deckFile,
        waitForGui = false,
        waitForLst = true,
        waitForTmp = true,
        timeoutMs = 100,
        extraDelayMs = 0,
      ) == wrTimeout
      check process.running

    test "returns ready after an extra delay while the process remains alive":
      let process = startSleepChild(500)
      defer: process.stopAndClose()

      check waitReady(
        process,
        testDirectory / "alive-during-delay.dck",
        waitForGui = false,
        waitForLst = false,
        waitForTmp = false,
        timeoutMs = 100,
        extraDelayMs = 50,
      ) == wrReady

    test "returns exited when the process stops during the extra delay":
      let process = startSleepChild(50)
      defer: process.stopAndClose()

      check waitReady(
        process,
        testDirectory / "exited-during-delay.dck",
        waitForGui = false,
        waitForLst = false,
        waitForTmp = false,
        timeoutMs = 100,
        extraDelayMs = 500,
      ) == wrExited

  suite "GUI readiness":
    test "returns false when no matching GUI window appears":
      let process = startSleepChild(500)
      defer: process.stopAndClose()

      check not minimizeGui(
        process,
        guiClasses = ["TRNRunTestClassThatDoesNotExist"],
        timeoutMs = 50,
      )
      check process.running

runTests()
