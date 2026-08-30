## Implements the TRNRun command-line interface.
##
## Command-line entry point for launching and configuring TRNSYS
## simulations through the TRNRun execution engine. It acts as a thin
## wrapper around `simulate`, exposing its parameters via CLI flags, with
## an optional native file picker when no deck file is supplied.
##
## The option vocabulary itself lives in `cli`; this module only drives the
## parser, resolves the deck, and reports the outcome.

import std/parseopt
import ./cli
import ./eventsink
import ./filedialog
import ./simulate
import ./status

const NimblePkgVersion {.strdefine.} = "unknown"

proc reportOutcome(outcome: SimResult, message: string): int =
  ## Emits one structured terminal status for command paths that cannot enter
  ## `simulate`, then returns the matching process exit code.
  let eventSink = stdoutEventSink()
  eventSink(statusEvent(outcome.status, message = message))
  return outcome.exitCode()

proc main(): int =
  ## Collects user input from the command line and runs one simulation.
  ##
  ## Returns the process exit code: 0 done, 1 fatal, 2 usage or validation
  ## error, 124 timeout, 125 stalled, or 130 cancelled.
  ##
  ## This procedure does not call `quit`, ensuring its `defer` and `finally`
  ## cleanup can run. Command failures that occur before `simulate` emit a
  ## structured terminal status through `reportOutcome`.
  var input = DefaultCliInput

  var parser = initOptParser()
  while true:
    parser.next()
    case parser.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case parser.key
      of "help", "h":
        echo HelpText
        return 0
      of "version", "v":
        echo NimblePkgVersion
        return 0
      else:
        if not input.applyOption(parser.key, parser.val):
          return reportOutcome(
            simInvalid,
            "Unknown option: " & parser.key,
          )
    of cmdArgument:
      if input.deckFile != "":
        return reportOutcome(
          simInvalid,
          "Unexpected argument: " & parser.key,
        )
      input.deckFile = parser.key

  if input.deckFile == "":
    input.deckFile = openDeckFileDialog()
    if input.deckFile == "":
      return reportOutcome(simCancelled, "No file selected")

  return exitCode(simulate(input.deckFile, input.settings))

when isMainModule:
  let code =
    try:
      main()
    except CatchableError:
      # CLI trust boundary: parse failures become one structured event rather
      # than an stderr-only diagnostic or an unhandled stack trace.
      reportOutcome(simInvalid, getCurrentExceptionMsg())
  quit(code)
