import std/[options, os, unittest]

import ../src/trnrun
import ./fake_trnrun


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc runRecorded(
    deckFile: string,
    trnrunPath = getAppFilename(),
    trnrunArgs: openArray[string] = [],
): tuple[outcome: RunResult, events: seq[string]] =
  ## Runs TRNRun as `run-7`, recording `<launch>` and every output line in order.
  var events: seq[string] = @[]

  proc onLaunch() {.gcsafe, raises: [].} =
    events.add("<launch>")

  proc onOutput(line: string) {.gcsafe, raises: [].} =
    events.add(line)

  let outcome = runTrnrun("run-7", deckFile, trnrunPath, trnrunArgs, onLaunch, onOutput)
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

      check outcome == (exitCode: some(0), error: "")
      check events == @["<launch>"] & @DoneLines

    test "merges stderr into the forwarded output":
      let (outcome, events) = runRecorded(createDeck(testDirectory, "streams.dck"))

      check outcome == (exitCode: some(3), error: "")
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

runTests()
