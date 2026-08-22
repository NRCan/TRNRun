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

proc parseGuiVisibility(s: string): TrnexeGuiVisibility =
  ## Parses a CLI visibility string into a `TrnexeGuiVisibility`; raises `ValueError` on unknown input.
  case s.toLowerAscii()
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
    raise newException(ValueError, "Invalid guiVisibility: " & s)


proc writeHelp() =
  ## Prints CLI usage to stdout.
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
  --detectTimeout:MS      Readiness timeout, 0 = unlimited (default: 0)
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
  ## Entry point for the TRNRun CLI.
  ##
  ## Parses command-line flags into `RunnerSettings`, opens a native file
  ## picker when no deck file is supplied, and runs the simulation.
  ##
  ## Returns
  ## -------
  ## int
  ##     Process exit code describing the outcome: 0 done, 1 fatal,
  ##     2 usage/validation error, 124 timeout, 125 stalled, 130 cancelled.
  ##     The caller is responsible for calling `quit` with this value; this
  ##     proc itself never calls `quit`, so any future `defer`/`finally`
  ##     cleanup added here is guaranteed to run.
  ##
  ## Raises
  ## ------
  ## ValueError, IOError
  ##     Invalid flag values or a missing deck/executable propagate to the
  ##     top-level handler, which prints one line and exits with code 2.
  var
    deckFile = ""
    settings = DefaultRunnerSettings

  var p = initOptParser()
  while true:
    p.next()
    case p.kind
    of cmdEnd:
      break
    of cmdShortOption, cmdLongOption:
      case p.key
      of "help", "h":
        writeHelp()
        return 0
      of "version", "v":
        echo NimblePkgVersion
        return 0
      of "deckFile":
        deckFile = p.val
      of "trnexePath":
        settings.trnexePath = p.val
      of "guiVisibility":
        settings.guiVisibility = parseGuiVisibility(p.val)
      of "waitForGui":
        settings.waitForGui = parseBool(p.val)
      of "waitForLst":
        settings.waitForLst = parseBool(p.val)
      of "waitForTmp":
        settings.waitForTmp = parseBool(p.val)
      of "detectTimeout":
        settings.detectTimeoutMs = parseInt(p.val)
      of "extraDelay":
        settings.extraDelayMs = parseInt(p.val)
      of "watchLog":
        settings.watchLog = parseBool(p.val)
      of "watchTmp":
        settings.watchTmp = parseBool(p.val)
      of "watchTimeout":
        settings.watchTimeoutMs = parseInt(p.val)
      of "stallTimeout":
        settings.stallTimeoutMs = parseInt(p.val)
      of "pollMs":
        settings.pollMs = parseInt(p.val)
      of "clean":
        settings.cleanOnSuccess = parseBool(p.val)
      of "killOnTimeout":
        settings.killOnTimeout = parseBool(p.val)
      of "killOnStall":
        settings.killOnStall = parseBool(p.val)
      of "severity":
        settings.severity = parseEnum[LogSeverity](p.val)
      of "writeEvents":
        settings.writeEvents = parseBool(p.val)
      else:
        stderr.writeLine("Unknown option: ", p.key)
        return 2
    of cmdArgument:
      if deckFile != "":
        stderr.writeLine("Unexpected argument: ", p.key)
        return 2
      deckFile = p.key
  if deckFile == "":
    deckFile = openDeckFileDialog()
    if deckFile == "":
      echo "No file selected."
      return 0

  deckFile = validateDeck(deckFile)
  settings.trnexePath = validateTrnexe(settings.trnexePath)

  # An unopenable trail is a startup error, not a warning: nothing is running
  # yet, and a lone stderr line is dropped by the manager's event parser.
  var jsonlOutput: JsonlWriter = nil
  if settings.writeEvents:
    jsonlOutput = openJsonlWriter(deckFile.changeFileExt("jsonl"))

  defer:
    jsonlOutput.close()

  let eventSink = sequencedEventSink(
    proc(line: string) =
      jsonlOutput.write(line)
      stdout.writeLine(line)
      stdout.flushFile()
  )

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
