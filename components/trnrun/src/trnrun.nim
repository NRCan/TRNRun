## Implements the TRNRun command-line interface.
##
## A thin wrapper around `simulate` that exposes its settings as CLI flags and
## opens a native file picker when no deck file is supplied. Option parsing and
## help text live in `cli`; this module resolves the deck and reports the outcome.

import std/os
import ./[cli, eventsink, filedialog, simulate, status]

const NimblePkgVersion {.strdefine.} = "unknown"

proc reportOutcome(outcome: SimResult, message: string, runId: string = ""): int =
  ## Emits a terminal status for paths that never reach `simulate`; returns its exit code.
  let eventSink = stdoutEventSink(runId = runId)
  eventSink(statusEvent(outcome.status, message = message))
  return outcome.exitCode()

proc main(): int =
  ## Parses the command line and runs one simulation, returning the process exit code.
  ##
  ## Never calls `quit`, so `finally` cleanup still runs; failures before `simulate`
  ## emit a terminal status through `reportOutcome`.
  let command =
    try:
      parseCommandLine(commandLineParams())
    except ValueError as error:
      return reportOutcome(simInvalid, error.msg)
  case command.action
  of caHelp:
    echo HelpText
    return 0
  of caVersion:
    echo NimblePkgVersion
    return 0
  of caRun:
    discard

  var input = command.input
  if input.deckFile == "":
    input.deckFile = openDeckFileDialog()
    if input.deckFile == "":
      return reportOutcome(simCancelled, "No file selected", input.runId)

  return simulate(input.deckFile, input.settings, input.runId).exitCode()

when isMainModule:
  let code =
    try:
      main()
    except CatchableError:
      # CLI trust boundary: unexpected failures become one structured event
      # rather than an stderr-only diagnostic or an unhandled stack trace.
      reportOutcome(simInvalid, getCurrentExceptionMsg())
  quit(code)
