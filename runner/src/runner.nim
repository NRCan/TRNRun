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
import ./monitor
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

proc exitCode*(code: SimMonitorResult): int =
  ## Maps a `SimMonitorResult` to a conventional process exit code.
  case code
  of monitorDone: 0
  of monitorCancelled: 130
  of monitorFatal: 1
  of monitorTimeout: 124
  of monitorStalled: 125

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
  ## Parses command-line flags into `simulate` parameters, opens a native
  ## file picker when no deck file is supplied, and runs the simulation.
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
    trnexePath = DefaultTrnexePath
    guiVisibility = DefaultGuiVisibility
    waitForGui = true
    waitForLst = true
    waitForTmp = false
    detectTimeoutMs = 0
    extraDelayMs = 0
    watchLog = true
    watchTmp = false
    watchTimeoutMs = 0
    stallTimeoutMs = 0
    pollMs = 100
    cleanOnSuccess = false
    killOnTimeout = false
    killOnStall = false
    severity = Notice
    writeEvents = false
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
        trnexePath = p.val
      of "guiVisibility":
        guiVisibility = parseGuiVisibility(p.val)
      of "waitForGui":
        waitForGui = parseBool(p.val)
      of "waitForLst":
        waitForLst = parseBool(p.val)
      of "waitForTmp":
        waitForTmp = parseBool(p.val)
      of "detectTimeout":
        detectTimeoutMs = parseInt(p.val)
      of "extraDelay":
        extraDelayMs = parseInt(p.val)
      of "watchLog":
        watchLog = parseBool(p.val)
      of "watchTmp":
        watchTmp = parseBool(p.val)
      of "watchTimeout":
        watchTimeoutMs = parseInt(p.val)
      of "stallTimeout":
        stallTimeoutMs = parseInt(p.val)
      of "pollMs":
        pollMs = parseInt(p.val)
      of "clean":
        cleanOnSuccess = parseBool(p.val)
      of "killOnTimeout":
        killOnTimeout = parseBool(p.val)
      of "killOnStall":
        killOnStall = parseBool(p.val)
      of "severity":
        severity = parseEnum[LogSeverity](p.val)
      of "writeEvents":
        writeEvents = parseBool(p.val)
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
  trnexePath = validateTrnexe(trnexePath)

  # An unopenable trail is a startup error, not a warning: nothing is running
  # yet, and a lone stderr line is dropped by the manager's event parser.
  var jsonlOutput: JsonlWriter = nil
  if writeEvents:
    jsonlOutput = openJsonlWriter(deckFile.changeFileExt("jsonl"))

  defer:
    jsonlOutput.close()

  let eventSink = proc(event: SimulationEvent) =
    let line = event.toJsonLine()
    jsonlOutput.write(line)
    stdout.writeLine(line)
    stdout.flushFile()

  let simResult = simulate(
    deckFile = deckFile,
    eventSink = eventSink,
    trnexePath = trnexePath,
    guiVisibility = guiVisibility,
    waitForGui = waitForGui,
    waitForLst = waitForLst,
    waitForTmp = waitForTmp,
    detectTimeoutMs = detectTimeoutMs,
    extraDelayMs = extraDelayMs,
    watchLog = watchLog,
    watchTmp = watchTmp,
    watchTimeoutMs = watchTimeoutMs,
    stallTimeoutMs = stallTimeoutMs,
    pollMs = pollMs,
    cleanOnSuccess = cleanOnSuccess,
    killOnTimeout = killOnTimeout,
    killOnStall = killOnStall,
    severity = severity,
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
