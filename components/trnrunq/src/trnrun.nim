## Runs one trnrun process from spawn through output capture and exit.
##
## This module owns one child process, forwards its merged output unchanged, and
## waits for it to finish. The configured runner owns its JSONL contract.

when not defined(windows):
  {.error: "trnrun.nim is Windows-only.".}

import std/[options, os, osproc, streams]
import ./outputsink
import ./status
import ./validate


proc runTrnrun*(
    deckFile: string,
    runnerPath: string,
    runID: string,
    runnerArgs: openArray[string],
    output: var OutputSink,
): Option[int] =
  ## Runs one child synchronously and returns its exit code when launched.
  ## Validation and launch failures emit a terminal error and return `none`.

  var process: Process = nil
  try:
    let
      deck = validateDeck(deckFile)
      executable = validateTrnrun(runnerPath)
    process = startProcess(
      executable,
      args = @[deck] & @runnerArgs & @["--runID:" & runID],
      options = {poStdErrToStdOut, poDaemon},
    )
  except CatchableError:
    output.emit(errorLine(runID, getCurrentExceptionMsg()))
    return none(int)

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

    result = some(process.waitForExit())
  finally:
    try:
      if process.running:
        process.kill()
    finally:
      process.close()
