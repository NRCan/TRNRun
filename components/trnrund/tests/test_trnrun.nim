import std/[monotimes, options, os, times, unittest]

import ../src/trnrun
import ./fake_trnrun


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

type CancelPoint = enum
  ## When `runRecorded` asks TRNRun to stop.
  cpNever
  cpBeforeLaunch
  cpAfterLaunch

proc runRecorded(
    deckFile: string,
    trnrunPath = getAppFilename(),
    trnrunArgs: openArray[string] = [],
    cancelPoint = cpNever,
): tuple[outcome: RunResult, events: seq[string]] =
  ## Runs TRNRun as `run-7`, recording `<launch>` and every output line in order.
  var events: seq[string] = @[]

  proc onLaunch() {.gcsafe, raises: [].} =
    events.add("<launch>")

  proc onOutput(line: string) {.gcsafe, raises: [].} =
    events.add(line)

  proc isCancelled(): bool {.gcsafe, raises: [].} =
    case cancelPoint
    of cpNever: false
    of cpBeforeLaunch: true
    of cpAfterLaunch: events.len > 0

  let outcome =
    runTrnrun("run-7", deckFile, trnrunPath, trnrunArgs, onLaunch, onOutput, isCancelled)
  result = (outcome: outcome, events: events)

proc runTests() =
  let testDirectory = getTempDir() / "trnrund_trnrun_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "TRNRun process":
    test "forwards every output line after onLaunch and returns the exit code":
      let (outcome, events) = runRecorded(createDeck(testDirectory, "done.dck"))

      check outcome == (exitCode: some(0), error: "", cancelled: false)
      check events == @["<launch>"] & @DoneLines

    test "merges stderr into the forwarded output":
      let (outcome, events) = runRecorded(createDeck(testDirectory, "streams.dck"))

      check outcome == (exitCode: some(3), error: "", cancelled: false)
      check events == @["<launch>", "to stdout", "to stderr"]

    test "passes the deck, the extra arguments, then the runId":
      let deckFile = createDeck(testDirectory, "args.dck")
      let (outcome, events) =
        runRecorded(deckFile, trnrunArgs = ["--pollMs:50", "--clean:true"])

      check outcome.exitCode == some(0)
      check events ==
        @["<launch>", deckFile, "--pollMs:50", "--clean:true", "--runId:run-7"]

    test "reports a launch failure without an exit code or callbacks":
      let (outcome, events) = runRecorded(
        createDeck(testDirectory, "done.dck"),
        trnrunPath = testDirectory / "missing-trnrun.exe",
      )

      check outcome.exitCode.isNone
      check outcome.error.len > 0
      check events.len == 0

    test "skips the launch when cancelled before it":
      let deckFile = createDeck(testDirectory, "args-cancelled.dck")
      let (outcome, events) = runRecorded(deckFile, cancelPoint = cpBeforeLaunch)

      check outcome == (exitCode: none(int), error: "", cancelled: true)
      check events.len == 0

    test "kills a running TRNRun when cancelled":
      let deckFile = createDeck(testDirectory, "gate-cancelled.dck")
      let started = getMonoTime()
      let (outcome, events) = runRecorded(deckFile, cancelPoint = cpAfterLaunch)

      check outcome.cancelled
      check outcome.exitCode.isSome
      check outcome.error == ""
      check events == @["<launch>"]
      check getMonoTime() - started < initDuration(seconds = 5) # The gate waits 10 s.
      check not fileExists(deckFile.changeFileExt("released"))

runTests()
