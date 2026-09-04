## Implements the TRNRun command-line interface.
##
## Command-line entry point for launching and configuring TRNSYS
## simulations through the TRNRun execution engine. It acts as a thin
## wrapper around `simulate`, exposing its parameters via CLI flags, with
## an optional native file picker when no deck file is supplied.
##
## Option parsing itself lives in `cli`; this module owns executable metadata,
## drives the parser, resolves the deck, and reports the outcome.

import std/parseopt
import ./cli
import ./eventsink
import ./filedialog
import ./simulate
import ./status

const NimblePkgVersion {.strdefine.} = "unknown"
const HelpText = """trnrun - launch and monitor TRNSYS simulations
Usage:
  trnrun [deckFile] [options]     # no deckFile -> opens a file picker

  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --deckFile:PATH         Deck path; same as the positional argument
  --runId:ID              Attach an opaque run identifier to every event
  --trnexePath:PATH       Path to TrnEXE64.exe
  --guiVisibility:MODE    keep | auto | min | minauto | hidden   (default: hidden)
  --waitForGui:BOOL       (default: true)
  --waitForLst:BOOL       (default: true)
  --waitForTmp:BOOL       (default: false)
  --detectTimeout:MS      Readiness timeout, 0 = unlimited (default: 300000)
  --extraDelay:MS         (default: 0)
  --watchLog:BOOL         (default: true)
  --watchTmp:BOOL         Needed for stall detection (default: false)
  --watchTimeout:MS       0 = unlimited (default: 0)
  --stallTimeout:MS       0 = disabled (default: 0)
  --pollMs:MS             (default: 100)
  --clean:BOOL            (default: false)
  --killOnTimeout:BOOL    (default: false)
  --killOnStall:BOOL      (default: false)
  --severity:LEVEL        Notice | Warning | Fatal (default: Notice)
  --writeEvents:BOOL      (default: false)

Exit codes: 0 done  1 fatal  2 usage error  124 timeout  125 stalled  130 cancelled"""

proc reportOutcome(outcome: SimResult, message: string, runId: string = ""): int =
  ## Emits one structured terminal status for command paths that cannot enter
  ## `simulate`, then returns the matching process exit code.
  let eventSink = stdoutEventSink(runId = runId)
  eventSink(statusEvent(outcome.status, message = message))
  return outcome.exitCode()


proc main(): int =
  ## Collects user input from the command line and runs one simulation.
  ##
  ## Returns the process exit code: 0 done, 1 fatal, 2 usage or validation
  ## error, 124 timeout, 125 stalled, or 130 cancelled.
  ##
  ## This procedure does not call `quit`, ensuring its `finally` cleanup can
  ## run. Command failures that occur before `simulate` emit a
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
        try:
          if not input.applyOption(parser.key, parser.val):
            return reportOutcome(
              simInvalid,
              "Unknown option: " & parser.key,
              input.runId,
            )
        except CatchableError:
          return reportOutcome(simInvalid, getCurrentExceptionMsg(), input.runId)
    of cmdArgument:
      if input.deckFile != "":
        return reportOutcome(
          simInvalid,
          "Unexpected argument: " & parser.key,
          input.runId,
        )
      input.deckFile = parser.key

  if input.deckFile == "":
    input.deckFile = openDeckFileDialog()
    if input.deckFile == "":
      return reportOutcome(simCancelled, "No file selected", input.runId)

  return exitCode(simulate(
    deckFile = input.deckFile,
    settings = input.settings,
    runId = input.runId,
  ))

when isMainModule:
  let code =
    try:
      main()
    except CatchableError:
      # CLI trust boundary: unexpected failures become one structured event
      # rather than an stderr-only diagnostic or an unhandled stack trace.
      reportOutcome(simInvalid, getCurrentExceptionMsg())
  quit(code)
