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
import ./filedialog
import ./simulate
import ./status

const NimblePkgVersion {.strdefine.} = "unknown"

proc main(): int =
  ## Collects user input from the command line and runs one simulation.
  ##
  ## Returns the process exit code: 0 done, 1 fatal, 2 usage or validation
  ## error, 124 timeout, 125 stalled, or 130 cancelled.
  ##
  ## This procedure does not call `quit`, ensuring its `defer` and `finally`
  ## cleanup can run. Invalid values and validation failures propagate to the
  ## top-level error boundary, which emits one diagnostic and returns code 2.
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
          stderr.writeLine("[Runner] Unknown option: ", parser.key)
          return 2
    of cmdArgument:
      if input.deckFile != "":
        stderr.writeLine("[Runner] Unexpected argument: ", parser.key)
        return 2
      input.deckFile = parser.key

  if input.deckFile == "":
    input.deckFile = openDeckFileDialog()
    if input.deckFile == "":
      stderr.writeLine("[Runner] No file selected.")
      return exitCode(simCancelled)

  return exitCode(simulate(input.deckFile, input.settings))

when isMainModule:
  let code =
    try:
      main()
    except CatchableError:
      # CLI trust boundary: a bad flag value or a missing deck/exe should print
      # one clean line and exit 2, not dump a stack trace.
      stderr.writeLine("[Runner] Error: ", getCurrentExceptionMsg())
      2
  quit(code)
