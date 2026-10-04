## Runs one trnrun process from launch through output capture and exit.
##
## `runTrnrun` blocks the calling worker thread for the whole run: it validates
## and launches TRNRun, forwards each line of its merged stdout and stderr
## unchanged, and returns the outcome.
##
## Children inherit the daemon's kill-on-close Job Object, so they cannot
## outlive it.

when not defined(windows):
  {.error: "trnrun.nim is Windows-only.".}

import std/[options, os, osproc, streams]
import ./validate

type
  LaunchCallback* = proc() {.gcsafe, raises: [].}
  OutputCallback* = proc(line: string) {.gcsafe, raises: [].}

  RunResult* = tuple
    exitCode: Option[int] ## None when TRNRun never launched.
    error: string ## Validation, launch, or capture failure; empty otherwise.

const PollMs = 10 ## Wait between output polls while TRNRun is silent.

# TRNRun process

proc launch(
    runId, deckFile, trnrunPath: string, trnrunArgs: openArray[string]
): Process =
  ## Validates the inputs and starts TRNRun. Raises on failure.
  let
    deck = validateDeck(deckFile)
    executable = validateTrnrun(trnrunPath)
  result = startProcess(
    executable,
    args = @[deck] & @trnrunArgs & @["--runId:" & runId],
    options = {poStdErrToStdOut, poDaemon},
  )

proc forwardLine(process: Process, line: var string, onOutput: OutputCallback) =
  if process.outputStream.readLine(line):
    onOutput(line)

proc capture(process: Process, onOutput: OutputCallback): int =
  ## Forwards output until TRNRun exits, then drains the pipe and returns
  ## the exit code.
  var line = ""
  while process.running:
    if process.hasData():
      process.forwardLine(line, onOutput)
    else:
      sleep(PollMs)

  result = process.waitForExit()
  while process.hasData():
    process.forwardLine(line, onOutput)

proc release(process: Process) =
  ## Kills a still-running TRNRun process and closes its handles and pipes.
  try:
    if process.running:
      process.kill()
  finally:
    process.close()

# Public API

proc runTrnrun*(
    runId, deckFile, trnrunPath: string,
    trnrunArgs: openArray[string],
    onLaunch: LaunchCallback,
    onOutput: OutputCallback,
): RunResult =
  ## Runs one TRNRun process synchronously and returns its outcome.
  ##
  ## Validation and launch failures return no exit code. `onLaunch` runs once
  ## the child exists and before any output. Callbacks run on the calling
  ## thread and must return promptly.
  result = (exitCode: none(int), error: "")

  let process =
    try:
      launch(runId, deckFile, trnrunPath, trnrunArgs)
    except CatchableError:
      result.error = getCurrentExceptionMsg()
      return

  onLaunch()
  try:
    result.exitCode = some(process.capture(onOutput))
  except CatchableError:
    result.error = getCurrentExceptionMsg()

  try:
    process.release()
  except CatchableError:
    if result.error.len == 0:
      result.error = getCurrentExceptionMsg()

# Direct-run example
when isMainModule:
  import ./job

  proc onLaunch() {.gcsafe, raises: [].} =
    echo "launched"

  proc onOutput(line: string) {.gcsafe, raises: [].} =
    echo line

  initJobGuard()

  let outcome = runTrnrun(
    runId = "example",
    deckFile = r"C:\Users\alexl\Documents\Project\Coding\NRCan\TRNRun_V6\TRNRun\components\trnrund\examples\dck\example_w_plot_w_tracking.dck",
    trnrunPath = r"C:\Users\alexl\Documents\Project\Coding\NRCan\TRNRun_V6\TRNRun\components\trnrun\build\trnrun.exe",
    trnrunArgs = ["--guiVisibility:minAuto", "--watchTmp:true"],
    onLaunch = onLaunch,
    onOutput = onOutput,
  )
  echo "exitCode: ", outcome.exitCode, ", error: '", outcome.error, "'"
