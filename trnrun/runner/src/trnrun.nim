## TRNRun - Command Line Interface for TRNSYS Simulation Execution
##
## This module provides a command-line entry point for launching and
## configuring TRNSYS simulations through the TRNRun execution engine.
## It acts as a thin wrapper around `simulate`, exposing its parameters via
## CLI flags and optional GUI file selection.

import std/[parseopt, strutils]
import ./simulate
import ./monitor
import ./filedialog

const NimblePkgVersion {.strdefine.} = "unknown"

proc parseGuiVisibility(s: string): TrnexeGuiVisibility =
  case s.toLowerAscii()
  of "keep", "keepopen":
    guiKeepOpen
  of "auto", "autoclose":
    guiAutoClose
  of "hidden":
    guiHidden
  else:
    raise newException(ValueError, "Invalid guiVisibility: " & s)

proc exitCode*(code: SimMonitorResult): int =
  case code
  of monitorDone: 0
  of monitorCancelled: 130
  of monitorFatal: 1
  of monitorTimeout: 124
  of monitorStalled: 125

proc writeHelp() =
  echo """trnrun - launch and monitor TRNSYS simulations

Usage:
  trnrun [deckFile] [options]     # no deckFile -> opens a file picker

  -h, --help              Show this help and exit
  -v, --version           Show version and exit
  --trnexePath:PATH       Path to TrnEXE64.exe
  --guiVisibility:MODE    keep | auto | hidden   (default: hidden)
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
  --writeLog:BOOL         (default: true)

Exit codes: 0 done  1 fatal  124 timeout  125 stalled  130 cancelled"""

proc main() =
  ## Entry point for the TRNRun CLI: parses command-line arguments
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
    writeLog = true
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
        return
      of "version", "v":
        echo NimblePkgVersion
        return
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
      of "writeLog":
        writeLog = parseBool(p.val)
      else:
        stderr.writeLine("Unknown option: ", p.key)
        quit(2)
    of cmdArgument:
      if deckFile == "":
        deckFile = p.key
  if deckFile == "":
    deckFile = openDeckFileDialog()
    if deckFile == "":
      echo "No file selected."
      return
  let result = simulate(
    deckFile = deckFile,
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
    writeLog = writeLog,
  )
  quit(exitCode(result))

when isMainModule:
  main()
