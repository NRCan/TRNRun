## runner.nim - command-line interface for TRNRun.
##
## Command-line entry point for launching and configuring TRNSYS
## simulations through the TRNRun execution engine. It acts as a thin
## wrapper around `simulate`, exposing its parameters via CLI flags, with
## an optional native file picker when no deck file is supplied.

import std/[os, parseopt, strutils]
import ./events
import ./eventsink
import ./simulate
import ./status
import ./settings
import ./filedialog

const NimblePkgVersion {.strdefine.} = "unknown"

proc parseGuiVisibility(value: string): TrnexeGuiVisibility =
  ## Parses a CLI visibility string into a `TrnexeGuiVisibility`; raises
  ## `ValueError` on unknown input.
  case value.toLowerAscii()
  of "keep", "keepopen":
    guiKeepOpen
  of "auto", "autoclose":
    guiAutoClose
  of "min", "minimized":
    guiMinimized
  of "minauto", "minimizedauto":
    guiMinimizedAuto
  of "hidden":
    guiHidden
  else:
    raise newException(ValueError, "Invalid guiVisibility: " & value)

proc writeHelp() =
  echo """trnrun - launch and monitor TRNSYS simulations

Usage:
  trnrun [deckFile] [options]     # no deckFile -> opens a file picker

  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --deckFile:PATH         Deck path; same as the positional argument
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

proc main(): int =
  ## Parses CLI options, selects a deck when necessary, runs the simulation,
  ## and returns its process exit code: 0 done, 1 fatal, 2 usage or validation
  ## error, 124 timeout, 125 stalled, or 130 cancelled.
  ##
  ## This procedure does not call `quit`, ensuring its `defer` and `finally`
  ## cleanup can run. Invalid values and validation failures propagate to the
  ## top-level error boundary, which emits one diagnostic and returns code 2.
  var
    deckFile = ""
    settings = DefaultRunnerSettings

  var parser = initOptParser()
  while true:
    parser.next()
    case parser.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case parser.key
      of "help", "h":
        writeHelp()
        return 0
      of "version", "v":
        echo NimblePkgVersion
        return 0
      of "deckFile":
        deckFile = parser.val
      of "trnexePath":
        settings.trnexePath = parser.val
      of "guiVisibility":
        settings.guiVisibility = parseGuiVisibility(parser.val)
      of "waitForGui":
        settings.waitForGui = parseBool(parser.val)
      of "waitForLst":
        settings.waitForLst = parseBool(parser.val)
      of "waitForTmp":
        settings.waitForTmp = parseBool(parser.val)
      of "detectTimeout":
        settings.detectTimeoutMs = parseInt(parser.val)
      of "extraDelay":
        settings.extraDelayMs = parseInt(parser.val)
      of "watchLog":
        settings.watchLog = parseBool(parser.val)
      of "watchTmp":
        settings.watchTmp = parseBool(parser.val)
      of "watchTimeout":
        settings.watchTimeoutMs = parseInt(parser.val)
      of "stallTimeout":
        settings.stallTimeoutMs = parseInt(parser.val)
      of "pollMs":
        settings.pollMs = parseInt(parser.val)
      of "clean":
        settings.cleanOnSuccess = parseBool(parser.val)
      of "killOnTimeout":
        settings.killOnTimeout = parseBool(parser.val)
      of "killOnStall":
        settings.killOnStall = parseBool(parser.val)
      of "severity":
        settings.severity = parseEnum[LogSeverity](parser.val)
      of "writeEvents":
        settings.writeEvents = parseBool(parser.val)
      else:
        stderr.writeLine("Unknown option: ", parser.key)
        return 2
    of cmdArgument:
      if deckFile != "":
        stderr.writeLine("Unexpected argument: ", parser.key)
        return 2
      deckFile = parser.key

  if deckFile == "":
    deckFile = openDeckFileDialog()
    if deckFile == "":
      stderr.writeLine("No file selected.")
      return exitCode(simCancelled)

  # Only the deck is resolved here, because the `.jsonl` path derives from it.
  # `simulate` validates both this and `trnexePath` itself.
  deckFile = validateDeck(deckFile)

  var jsonlOutput: JsonlWriter = nil

  if settings.writeEvents:
    try:
      jsonlOutput = openJsonlWriter(deckFile.changeFileExt("jsonl"))
    except IOError:
      # Keep the SETTING event honest: nothing will be written to a file.
      settings.writeEvents = false
      stderr.writeLine(
        "[JsonlWriter] Could not open event file (logging disabled): ",
        getCurrentExceptionMsg()
      )

  defer:
    try:
      jsonlOutput.close()
    except IOError:
      stderr.writeLine(
        "[JsonlWriter] Could not close event file: ",
        getCurrentExceptionMsg()
      )

  let eventSink = stdoutEventSink(jsonlOutput)

  let simResult = simulate(
    deckFile = deckFile,
    eventSink = eventSink,
    settings = settings,
  )

  exitCode(simResult)

when isMainModule:
  let code =
    try:
      main()
    except CatchableError:
      # CLI trust boundary: a bad flag value or a missing deck/exe should print
      # one clean line and exit 2, not dump a stack trace.
      stderr.writeLine("Error: ", getCurrentExceptionMsg())
      2
  quit(code)
