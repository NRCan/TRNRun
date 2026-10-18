## Implements the TRNRun command-line interface.
##
## A thin wrapper around `simulate` that exposes its settings as CLI flags and
## opens a native file picker when no deck file is supplied. Option parsing lives
## in `cli`; this module drives it, resolves the deck, and reports the outcome.

import std/parseopt
import ./[cli, eventsink, filedialog, simulate, status]

const
  NimblePkgVersion {.strdefine.} = "unknown"
  HelpText = """
trnrun - launch and monitor TRNSYS simulations
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
  ## Emits a terminal status for paths that never reach `simulate`; returns its exit code.
  let eventSink = stdoutEventSink(runId = runId)
  eventSink(statusEvent(outcome.status, message = message))
  return outcome.exitCode()

proc main(): int =
  ## Parses the command line and runs one simulation, returning the process exit code.
  ##
  ## Never calls `quit`, so `finally` cleanup still runs; failures before `simulate`
  ## emit a terminal status through `reportOutcome`.
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
            return reportOutcome(simInvalid, "Unknown option: " & parser.key, input.runId)
        except CatchableError:
          return reportOutcome(simInvalid, getCurrentExceptionMsg(), input.runId)
    of cmdArgument:
      if input.deckFile != "":
        return reportOutcome(simInvalid, "Unexpected argument: " & parser.key, input.runId)
      input.deckFile = parser.key

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
