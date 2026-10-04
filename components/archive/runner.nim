## Runs one trnrun process from spawn through output capture and exit.
##
## This module owns one child process and posts each line of its merged output
## to the daemon inbox unchanged; the daemon parses it.

when not defined(windows):
  {.error: "runner.nim is Windows-only.".}

import std/[options, os, osproc, streams]
import ./messages
import ./validate


proc runTrnrun*(work: Work, worker: int, inbox: var Channel[Message]) =
  ## Runs one child synchronously. Posts `mkLaunched` once the child exists,
  ## then exactly one `mkExited` message. Validation and launch failures skip
  ## `mkLaunched` and are reported without an exit code.
  var
    exitCode = none(int)
    error = ""
    process: Process = nil

  try:
    let
      deck = validateDeck(work.deckFile)
      executable = validateTrnrun(work.runnerPath)
    process = startProcess(
      executable,
      args = @[deck] & work.runnerArgs & @["--runId:" & work.runId],
      options = {poStdErrToStdOut, poDaemon},
    )
  except CatchableError:
    error = getCurrentExceptionMsg()

  if not process.isNil:
    inbox.send(Message(kind: mkLaunched, simulation: work.simulation, worker: worker))
    try:
      var line = ""
      while process.running:
        if process.hasData():
          if process.outputStream.readLine(line):
            inbox.send(Message(
              kind: mkOutput,
              simulation: work.simulation,
              worker: worker,
              line: line,
            ))
        else:
          sleep(10)

      while process.hasData():
        if process.outputStream.readLine(line):
          inbox.send(Message(
            kind: mkOutput,
            simulation: work.simulation,
            worker: worker,
            line: line,
          ))

      exitCode = some(process.waitForExit())
    except CatchableError:
      error = getCurrentExceptionMsg()
    finally:
      try:
        if process.running:
          process.kill()
      finally:
        process.close()

  inbox.send(Message(
    kind: mkExited,
    simulation: work.simulation,
    worker: worker,
    exitCode: exitCode,
    error: error,
  ))
