## simulate.nim - high-level TRNSYS execution engine.
##
## This module provides a high-level interface for launching, monitoring,
## and managing TRNSYS simulations via TrnEXE. It wraps process execution,
## readiness detection, and runtime monitoring into a single controlled
## workflow with structured status reporting.
##
## Key features:
## - Safe execution of TRNSYS decks (.dck / .trd)
## - Automatic validation of inputs and executable paths
## - Global execution locking to prevent concurrent conflicts
## - GUI visibility control, including synthesized "minimized" modes
## - Multi-signal readiness detection:
##     * GUI window detection
##     * .lst file creation
##     * .tmp file creation
## - Continuous runtime monitoring of:
##     * .log streaming events
##     * .tmp progress/config updates
## - Structured lifecycle, progress, and log events through an `EventSink`
## - Graceful handling of:
##     * Normal completion
##     * Crashes / fatal errors
##     * Timeouts (launch or runtime)
##     * Stalls (simulation time stops advancing)
##     * Cancellation
##
## Execution model:
##   simulate() orchestrates the full lifecycle:
##     VALIDATION → LAUNCH → RUNNING → COMPLETED
##
## Output:
## - Delivers structured lifecycle, progress, and log events through an
##   `EventSink` supplied by the caller.

import std/[os, osproc, strformat, strutils, times]
import ./events
import ./eventsink
import ./job
import ./mutex
import ./wait
import ./monitor

# ---------------------------------------------------------------------------
# Types & constants
# ---------------------------------------------------------------------------
type
  TrnexeLaunchError* = object of CatchableError
    ## Raised when TrnEXE fails to start.

  TrnexeGuiVisibility* = enum
    ## TrnEXE only supports three real CLI states (default / `/n` / `/h`).
    ## The minimized modes are synthesized: launch with a visible flag, then
    ## drive the windows into the minimized state via Win32.
    guiKeepOpen # Visible; window stays open after the run.
    guiAutoClose # Visible; window closes when the run finishes.
    guiMinimized # Minimized; window stays open after the run.
    guiMinimizedAuto # Minimized; window closes when the run finishes.
    guiHidden # No window at all.

  TrnRunConfig* = object
    ## Options controlling TRNSYS launch detection and runtime monitoring.
    trnexePath*: string
    guiVisibility*: TrnexeGuiVisibility
    waitForGui*: bool
    waitForLst*: bool
    waitForTmp*: bool
    detectTimeoutMs*: int
    extraDelayMs*: int
    watchLog*: bool
    watchTmp*: bool
    watchTimeoutMs*: int
    stallTimeoutMs*: int
    pollMs*: int
    cleanOnSuccess*: bool
    killOnTimeout*: bool
    killOnStall*: bool
    severity*: LogSeverity


const
  DefaultTrnexePath* = r"C:\TRNSYS18\Exe\TrnEXE64.exe" # Default TRNSYS 18 executable path.
  DefaultGuiVisibility* = guiHidden # GUI mode used when none is specified.
  DefaultTrnRunConfig* = TrnRunConfig(
    trnexePath: DefaultTrnexePath,
    guiVisibility: DefaultGuiVisibility,
    waitForGui: true,
    waitForLst: true,
    waitForTmp: false,
    detectTimeoutMs: 0,
    extraDelayMs: 0,
    watchLog: true,
    watchTmp: true,
    watchTimeoutMs: 0,
    stallTimeoutMs: 0,
    pollMs: 100,
    cleanOnSuccess: false,
    killOnTimeout: false,
    killOnStall: false,
    severity: Notice,
  )
    ## Default options for TRNSYS simulation runs.
  Extensions = [
    ".tmp", # Temporary progress file
    ".log", # Simulation log containing notice, warnings, and Fatal errors
    ".lst", # Simulation list file
    ".PTI", # Online Plotter file
  ]

func flag*(v: TrnexeGuiVisibility): string =
  ## The TrnEXE command-line switch for a visibility mode ("" = no switch).
  case v
  of guiKeepOpen, guiMinimized: ""
  of guiAutoClose, guiMinimizedAuto: "/n"
  of guiHidden: "/h"

func wantsMinimize*(v: TrnexeGuiVisibility): bool =
  ## True if the mode requires post-launch Win32 minimization.
  v in {guiMinimized, guiMinimizedAuto}


# ---------------------------------------------------------------------------
# Validation & file helpers
# ---------------------------------------------------------------------------
proc validateDeck*(deckFile: string): string =
  ## Resolves `deckFile` to an absolute, normalized path.
  ## Raises `IOError` if it is missing, or `ValueError` if it is not a `.dck`/`.trd`.
  result = deckFile.absolutePath().normalizedPath()
  if not fileExists(result):
    raise newException(IOError, fmt"Deck file not found: '{result}'")
  if result.splitFile().ext.toLowerAscii() notin [".dck", ".trd"]:
    raise newException(ValueError, fmt"Expected .dck or .trd, got: '{deckFile}'")

proc validateTrnexe*(trnexePath: string): string =
  ## Resolves the TRNSYS executable to an absolute, normalized path.
  ## Raises `IOError` if it does not exist.
  result = trnexePath.absolutePath().normalizedPath()
  if not fileExists(result):
    raise newException(IOError, fmt"TRNEXE not found: '{result}'")

# ---------------------------------------------------------------------------
# Launch TRNSYS
# ---------------------------------------------------------------------------
proc launchTrnexe*(
    deckFile: string,
    trnexePath: string = DefaultTrnexePath,
    guiVisibility: TrnexeGuiVisibility = DefaultGuiVisibility,
): Process =
  ## Spawns TrnEXE for `deckFile` and returns the process; raises `TrnexeLaunchError` on failure.
  result = default(Process)
  var args = @[deckFile]
  let switch = guiVisibility.flag()
  if switch.len > 0:
    args.add(switch)

  try:
    return startProcess(
      trnexePath, workingDir = deckFile.parentDir(), args = args, options = {}
    )
  except OSError, IOError:
    raise newException(
      TrnexeLaunchError, "Failed to launch TRNSYS: " & getCurrentExceptionMsg()
    )

proc unlinkFiles*(deckFile: string) =
  ## Deletes TRNSYS sidecar files for a deck, ignoring missing ones.
  for ext in Extensions:
    let f = deckFile.changeFileExt(ext)
    if fileExists(f) and not tryRemoveFile(f):
      stderr.writeLine(fmt"Warning: Could not delete {f} (likely in use).")


# ---------------------------------------------------------------------------
# Main simulation
# ---------------------------------------------------------------------------
proc simulate*(
    deckFile: string,
    eventSink: EventSink,
    config: TrnRunConfig = DefaultTrnRunConfig,
): SimMonitorResult =
  ## Launches and monitors a TRNSYS simulation, emitting structured events.
  ##
  ## Validates the deck and executable, acquires the global launch lock,
  ## starts TrnEXE, waits for the configured readiness signals (GUI window,
  ## `.lst` header, `.tmp` file), then monitors the run until completion,
  ## failure, cancellation, timeout, or stall. A `STATUS` event is emitted
  ## on every state transition; `CONFIG`/`PROGRESS`/`LOG` events are emitted
  ## while monitoring.
  ##
  ## Parameters
  ## ----------
  ## deckFile : string
  ##     Path to a `.dck` or `.trd` simulation deck.
  ## eventSink : EventSink
  ##     Destination for all structured events produced by the simulation.
  ## config : TrnRunConfig, optional
  ##     Launch detection, monitoring, cleanup, and logging options. Uses
  ##     `DefaultTrnRunConfig` when omitted.
  ##
  ## Returns
  ## -------
  ## SimMonitorResult
  ##     Final outcome: `monitorDone` (completed), `monitorFatal` (crashed
  ##     or failed), `monitorCancelled` (exited early), `monitorTimeout`
  ##     (watch timeout reached), or `monitorStalled` (progress stopped).
  ##
  ## Raises
  ## ------
  ## IOError
  ##     If the deck file or TRNSYS executable does not exist.
  ## ValueError
  ##     If `deckFile` is not a `.dck` or `.trd` file.
  let deckFile = validateDeck(deckFile)
  let trnexePath = validateTrnexe(config.trnexePath)

  try:
    initJobGuard()
  except OSError as e:
    stderr.writeLine("Warning: orphan guard unavailable, TrnEXE64.exe may outlive trnrun: ", e.msg)

  eventSink(statusEvent(statusPending))

  var process: Process = default(Process)
  var startTime: Time = default(Time)

  withLaunchLock:
    unlinkFiles(deckFile)
    eventSink(statusEvent(statusLaunching))

    try:
      process = launchTrnexe(deckFile, trnexePath, config.guiVisibility)
    except TrnexeLaunchError:
      eventSink(statusEvent(statusError))
      return monitorFatal
    startTime = getTime()

    let waitStatus = waitReady(
      process = process,
      deckFile = deckFile,
      waitForGui = config.waitForGui,
      waitForLst = config.waitForLst,
      waitForTmp = config.waitForTmp,
      timeoutMs = config.detectTimeoutMs,
      extraDelayMs = config.extraDelayMs,
    )

    case waitStatus
    of wrDied:
      if process.running:
        process.kill()
        eventSink(statusEvent(statusError))
        return monitorFatal
    of wrTimeout:
      if process.running and config.killOnTimeout:
        process.kill()
        eventSink(statusEvent(statusTimeout))
        return monitorTimeout
    else:
      discard

    if config.guiVisibility.wantsMinimize() and process.running:
      discard minimizeGui(process)

    eventSink(statusEvent(statusRunning))

  let monitorResult = monitor(
    process = process,
    deckFile = deckFile,
    startTime = startTime,
    eventSink = eventSink,
    watchLog = config.watchLog,
    watchTmp = config.watchTmp,
    pollMs = config.pollMs,
    severity = config.severity,
    watchTimeoutMs = config.watchTimeoutMs,
    stallTimeoutMs = config.stallTimeoutMs,
  )

  case monitorResult
  of monitorDone:
    eventSink(statusEvent(statusDone))
    if config.cleanOnSuccess:
      unlinkFiles(deckFile)
  of monitorFatal:
    eventSink(statusEvent(statusError))
  of monitorCancelled:
    eventSink(statusEvent(statusCancelled))
  of monitorStalled:
    if process.running and config.killOnStall:
      process.kill()

    eventSink(statusEvent(statusStalled))

    if process.running and not config.killOnStall:
      discard process.waitForExit()
  of monitorTimeout:
    if process.running and config.killOnTimeout:
      process.kill()

    eventSink(statusEvent(statusTimeout))

    if process.running and not config.killOnTimeout:
      discard process.waitForExit()

  return monitorResult

# ---------------------------------------------------------------------------
when isMainModule:
  let deckFile = absolutePath(r"examples\dck\example_w_plot_w_tracking.dck")
  var config = DefaultTrnRunConfig
  config.guiVisibility = guiMinimizedAuto

  let simResult = simulate(
    deckFile = deckFile,
    eventSink = stdoutEventSink(),
    config = config,
  )
  echo fmt"Simulation finished with result: {simResult}"
