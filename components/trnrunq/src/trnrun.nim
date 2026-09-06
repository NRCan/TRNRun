## Runs one trnrun process from spawn through output capture and exit.
##
## Runner output is authoritative. This module owns one child process, forwards
## its complete output lines, and waits for it to finish.

when not defined(windows):
  {.error: "trnrun.nim is Windows-only.".}

import std/[os, osproc, streams]
import ./outputsink
import ./status
import ./validate


proc runTrnrun*(
    deckFile: string,
    runnerPath: string,
    runId: string,
    runnerArgs: openArray[string],
    output: var OutputSink,
) =
  ## Runs one child synchronously and reports launch failures through `output`.
  var process: Process = nil
  try:
    let
      deck = validateDeck(deckFile)
      executable = validateTrnrun(runnerPath)
    process = startProcess(
      executable,
      args = @[deck] & @runnerArgs & @["--runId:" & runId],
      options = {poStdErrToStdOut, poDaemon},
    )
  except CatchableError:
    output.emit(errorLine(runId, getCurrentExceptionMsg()))
    return

  try:
    var line = ""
    while process.running:
      if process.hasData():
        if process.outputStream.readLine(line):
          output.emit(line)
      else:
        sleep(10)

    while process.hasData():
      if process.outputStream.readLine(line):
        output.emit(line)

    discard process.waitForExit()
  finally:
    if process.running:
      process.kill()
    process.close()
