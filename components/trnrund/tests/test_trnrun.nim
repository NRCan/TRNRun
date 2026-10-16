import std/[monotimes, options, os, osproc, times, unittest]

import ../src/trnrun
import ./[fake_deck, fake_trnrun]

proc runRecorded(
    deckFile: string,
    trnrunArgs: openArray[string] = [],
    killAfterFirstLine = false,
): tuple[outcome: CaptureResult, lines: seq[string]] =
  ## Launches TRNRun as run 7 and captures it on this thread, recording every line.
  let launched = launch(7, deckFile, getAppFilename(), trnrunArgs)
  defer: launched.process.close()
  var lines: seq[string] = @[]

  proc onOutput(line: string) {.gcsafe, raises: [].} =
    ## Records one output line.
    lines.add(line)

  if killAfterFirstLine:
    launched.process.kill() # Before reading: the pipe then ends without output.
  let outcome = captureOutput(launched.output, launched.waitHandle, onOutput)
  result = (outcome: outcome, lines: lines)

proc runTests() =
  ## Runs the launch and capture tests in a temporary directory.
  let testDirectory = getTempDir() / "trnrund_trnrun_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  suite "TRNRun process":
    test "forwards every output line, then returns the exit code":
      let (outcome, lines) = runRecorded(createDeck(testDirectory, "done.dck"))

      check outcome == (exitCode: some(0), error: "")
      check lines == @DoneLines

    test "merges stderr into the forwarded output":
      let (outcome, lines) = runRecorded(createDeck(testDirectory, "streams.dck"))

      check outcome == (exitCode: some(3), error: "")
      check lines == @["to stdout", "to stderr"]

    test "passes the deck, the extra arguments, then the runId":
      let deckFile = createDeck(testDirectory, "args.dck")
      let (outcome, lines) = runRecorded(deckFile, trnrunArgs = ["--pollMs:50", "--clean:true"])

      check outcome.exitCode == some(0)
      check lines == @[deckFile, "--pollMs:50", "--clean:true", "--runId:7"]

    test "raises when TRNRun cannot start":
      expect OSError:
        discard launch(1, createDeck(testDirectory, "done.dck"),
          testDirectory / "missing-trnrun.exe", [])

    test "ends the capture once TRNRun is killed":
      let deckFile = createDeck(testDirectory, "gate-killed.dck")
      let started = getMonoTime()
      let (outcome, lines) = runRecorded(deckFile, killAfterFirstLine = true)

      check outcome.exitCode.isSome
      check outcome.error == ""
      check lines.len == 0
      check getMonoTime() - started < initDuration(seconds = 5) # The gate waits 10 s.
      check not fileExists(deckFile.changeFileExt("released"))

    test "forwards a last line without a line break":
      let (outcome, lines) = runRecorded(createDeck(testDirectory, "partial.dck"))

      check outcome.exitCode == some(0)
      check lines == @["complete", "", "last"]

runTests()
