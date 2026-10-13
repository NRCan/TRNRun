## Runs one TRNRun process from launch through output capture and exit.
##
## `runTrnrun` blocks the calling worker thread for the whole run: it launches
## TRNRun, forwards each line of its merged stdout and stderr unchanged, and
## returns the outcome. TRNRun validates the deck itself and reports a missing
## one as an `ERROR` status.
##
## Children inherit the daemon's kill-on-close Job Object, so they cannot
## outlive it. Killing TRNRun to cancel a run also stops its TrnEXE, which
## TRNRun keeps in a kill-on-close Job Object of its own.

import std/[options, os, osproc, streams]

type
  LaunchCallback* = proc() {.gcsafe, raises: [].} ## Runs once TRNRun has started.
  OutputCallback* = proc(line: string) {.gcsafe, raises: [].} ## Gets one TRNRun line.
  CancelCallback* = proc(): bool {.gcsafe, raises: [].}
    ## Whether to stop the run; polled before launch and while TRNRun runs.

  RunResult* = tuple
    ## Outcome of one `runTrnrun` call.
    exitCode: Option[int] ## None when TRNRun never launched.
    error: string ## Launch or capture failure; empty otherwise.
    cancelled: bool ## Stopped by the cancel callback, before launch or by killing TRNRun.

const PollMs = 10 ## Wait between output polls while TRNRun is silent.

# TRNRun process

proc launch(
    runId, deckFile, trnrunPath: string, trnrunArgs: openArray[string]
): Process =
  ## Starts TRNRun. Raises when the process cannot start.
  result = startProcess(
    trnrunPath,
    args = @[deckFile] & @trnrunArgs & @["--runId:" & runId],
    options = {poStdErrToStdOut, poDaemon},
  )

proc forwardLine(process: Process, line: var string, onOutput: OutputCallback) =
  ## Forwards the next output line, unless the pipe has reached its end.
  if process.outputStream.readLine(line):
    onOutput(line)

proc capture(
    process: Process, onOutput: OutputCallback, isCancelled: CancelCallback
): tuple[exitCode: int, cancelled: bool] =
  ## Forwards output until TRNRun exits or is killed on cancellation, drains
  ## the pipe, and returns the exit code and whether it was killed.
  result = (exitCode: 0, cancelled: false)
  var line = ""
  while process.running:
    if isCancelled():
      process.kill()
      result.cancelled = true
      break
    if process.hasData():
      process.forwardLine(line, onOutput)
    else:
      sleep(PollMs)

  result.exitCode = process.waitForExit()
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
    isCancelled: CancelCallback,
): RunResult =
  ## Runs one TRNRun process synchronously and returns its outcome.
  ##
  ## A launch failure returns no exit code. `onLaunch` runs once the child
  ## exists and before any output. A run cancelled before launch returns at
  ## once, without an exit code or callbacks; one cancelled while running is
  ## killed. Callbacks run on the calling thread and must return promptly.
  result = (exitCode: none(int), error: "", cancelled: false)
  if isCancelled():
    result.cancelled = true
    return

  let process =
    try:
      launch(runId, deckFile, trnrunPath, trnrunArgs)
    except CatchableError as error:
      result.error = error.msg
      return

  onLaunch()
  try:
    let (exitCode, cancelled) = process.capture(onOutput, isCancelled)
    result.exitCode = some(exitCode)
    result.cancelled = cancelled
  except CatchableError as error:
    result.error = error.msg

  try:
    process.release()
  except CatchableError as error:
    if result.error.len == 0:
      result.error = error.msg
