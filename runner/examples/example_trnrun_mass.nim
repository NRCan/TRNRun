## Launch many copies of the same deck at once and wait for all of them.

import std/[os, osproc, strformat, streams, strutils]

const
  Copies = 50
  CleanCopies = false
  Params = [
    "--guiVisibility=Auto",
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
    "--writeEvents=false",
  ]

type Run = tuple[name: string, process: Process]

proc forwardOutputLine(run: Run) =
  var line = ""
  if run.process.outputStream().readLine(line):
    echo fmt"[{run.name}] {line}"

let
  examplesDir = currentSourcePath().parentDir()
  exe = examplesDir.parentDir() / "build" / "trnrun.exe"
  source = examplesDir / "dck" / "example_wo_plot_w_tracking.dck"
  stageDir = examplesDir / "stress"

if not fileExists(exe):
  quit("Executable not found: " & exe)
if not fileExists(source):
  quit("Deck not found: " & source)

if dirExists(stageDir):
  removeDir(stageDir)
createDir(stageDir)

var runs: seq[Run]
let padding = ($Copies).len

for i in 1 .. Copies:
  let
    name = "example_wo_plot_w_tracking_" & align($i, padding, '0')
    deck = stageDir / (name & ".dck")
  copyFile(source, deck)
  runs.add((
    name,
    startProcess(
      exe,
      args = @["--deckFile=" & deck] & @Params,
      options = {poStdErrToStdOut},
    ),
  ))

let runCount = runs.len
echo fmt"Launched {runCount} simulations. Waiting for completion..."

var failures = 0
while runs.len > 0:
  for i in countdown(runs.high, 0):
    let run = runs[i]

    # Read each active pipe in turn so no child can block on a full buffer.
    if run.process.hasData():
      run.forwardOutputLine()

    let exitCode = run.process.peekExitCode()
    if exitCode != -1:
      while run.process.hasData():
        run.forwardOutputLine()
      run.process.close()
      runs.delete(i)

      if exitCode != 0:
        inc failures
        echo fmt"{run.name} failed with exit code {exitCode}"

  if runs.len > 0:
    sleep(10)

echo fmt"Finished {runCount} simulations with {failures} failures."

if CleanCopies:
  removeDir(stageDir)
