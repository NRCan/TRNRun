## Launch many copies of the same slow deck at once and wait for all of them.
##
## Usage:
##
##   nim r tests/manual_concurrent.nim

import std/[os, osproc, strformat, streams, strutils]

const
  DeckFilename = "test_slow_wo_plot_w_tracking.dck"
  CopyCount = 50
  RemoveStagedCopies = false
  CliOptions = [
    "--guiVisibility=auto",
    "--waitForGui=true",
    "--waitForLst=true",
    "--waitForTmp=false",
    "--detectTimeout=0",
    "--extraDelay=0",
    "--watchLog=false",
    "--watchTmp=true",
    "--watchTimeout=0",
    "--stallTimeout=0",
    "--pollMs=1000",
    "--clean=false",
    "--killOnTimeout=true",
    "--killOnStall=true",
    "--severity=Notice",
    "--writeEvents=true",
  ]

type SimulationRun = tuple[name: string, process: Process]

proc forwardOutputLine(run: SimulationRun) =
  var line = ""
  if run.process.outputStream().readLine(line):
    echo fmt"[{run.name}] {line}"

let
  testsDirectory = currentSourcePath().parentDir()
  executablePath = testsDirectory.parentDir() / "build" / "trnrun.exe"
  sourceDeck = testsDirectory / "dck" / DeckFilename
  stagingDirectory = testsDirectory / "runs"

if not fileExists(executablePath):
  quit("Executable not found: " & executablePath)
if not fileExists(sourceDeck):
  quit("Deck not found: " & sourceDeck)

if dirExists(stagingDirectory):
  removeDir(stagingDirectory)
createDir(stagingDirectory)

var activeRuns: seq[SimulationRun]
let copyNumberWidth = ($CopyCount).len

for copyIndex in 1 .. CopyCount:
  let
    runName =
      sourceDeck.splitFile().name & "_" &
      align($copyIndex, copyNumberWidth, '0')
    stagedDeck = stagingDirectory / (runName & ".dck")
  copyFile(sourceDeck, stagedDeck)
  activeRuns.add((
    runName,
    startProcess(
      executablePath,
      args = @[
        "--runId=" & runName,
        "--deckFile=" & stagedDeck,
      ] & @CliOptions,
      options = {poStdErrToStdOut},
    ),
  ))

let runCount = activeRuns.len
echo fmt"Launched {runCount} simulations. Waiting for completion..."

var failureCount = 0
while activeRuns.len > 0:
  for runIndex in countdown(activeRuns.high, 0):
    let run = activeRuns[runIndex]

    # Read each active pipe in turn so no child can block on a full buffer.
    if run.process.hasData():
      run.forwardOutputLine()

    let exitCode = run.process.peekExitCode()
    if exitCode != -1:
      while run.process.hasData():
        run.forwardOutputLine()
      run.process.close()
      activeRuns.delete(runIndex)

      if exitCode != 0:
        inc failureCount
        echo fmt"{run.name} failed with exit code {exitCode}"

  if activeRuns.len > 0:
    sleep(10)

echo fmt"Finished {runCount} simulations with {failureCount} failures."

if RemoveStagedCopies:
  removeDir(stagingDirectory)

quit(if failureCount == 0: 0 else: 1)
