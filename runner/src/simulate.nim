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
## - Structured setting, lifecycle, progress, and log events through an `EventSink`
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
import ./settings
import ./status

export settings, status

# Types and constants
type
  TrnexeLaunchError* = object of CatchableError
    ## Raised when TrnEXE fails to start.

const
  Extensions = [
    ".tmp", # Temporary progress file
    ".log", # Simulation log containing notice, warnings, and Fatal errors
    ".lst", # Simulation list file
    ".PTI", # Online Plotter file
  ]

# Validation and file helpers
proc validateDeck*(deckFile: string): string =
  ## Resolves `deckFile` to an absolute, normalized path.
  ## Raises `IOError` if it is missing, or `ValueError` if it is not a
  ## `.dck`/`.trd`.
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

# Process launch
proc launchTrnexe*(
    deckFile: string,
    trnexePath: string = DefaultTrnexePath,
    guiVisibility: TrnexeGuiVisibility = DefaultGuiVisibility,
): Process =
  ## Spawns TrnEXE for `deckFile` and returns the process; raises
  ## `TrnexeLaunchError` on failure.
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


# Simulation
proc simulate*(
    deckFile: string,
    eventSink: EventSink,
    settings: RunnerSettings = DefaultRunnerSettings,
): SimResult =
  ## Launches and monitors a TRNSYS simulation, emitting structured events.
  ##
  ## Validates the deck and executable, acquires the global launch lock,
  ## starts TrnEXE, waits for the configured readiness signals (GUI window,
  ## `.lst` header, `.tmp` file), then monitors the run until completion,
  ## failure, cancellation, timeout, or stall. A `SETTING` event is emitted
  ## first, followed by `STATUS` events on every state transition;
  ## `CONFIG`/`PROGRESS`/`LOG` events are emitted while monitoring.
  ##
  ## Parameters
  ## ----------
  ## deckFile : string
  ##     Path to a `.dck` or `.trd` simulation deck.
  ## eventSink : EventSink
  ##     Destination for all structured events produced by the simulation.
  ## settings : RunnerSettings, optional
  ##     Launch detection, monitoring, cleanup, and logging settings. Uses
  ##     `DefaultRunnerSettings` when omitted.
  ##
  ## Returns
  ## -------
  ## SimResult
  ##     Final outcome: `simDone` (completed), `simFatal` (crashed or failed),
  ##     `simCancelled` (exited early), `simTimeout` (watch timeout reached),
  ##     or `simStalled` (progress stopped).
  ##
  ## Raises
  ## ------
  ## IOError
  ##     If the deck file or TRNSYS executable does not exist.
  ## ValueError
  ##     If `deckFile` is not a `.dck` or `.trd` file.
  let deckFile = validateDeck(deckFile)
  let trnexePath = validateTrnexe(settings.trnexePath)

  try:
    initJobGuard()
  except OSError as e:
    stderr.writeLine(
      "Warning: orphan guard unavailable, TrnEXE64.exe may outlive trnrun: ",
      e.msg,
    )

  eventSink(settingEvent(settings, trnexePath))
  eventSink(statusEvent(statusPending))

  var process: Process = default(Process)
  var startTime: Time = default(Time)

  withLaunchLock:
    unlinkFiles(deckFile)
    eventSink(statusEvent(statusLaunching))

    try:
      process = launchTrnexe(deckFile, trnexePath, settings.guiVisibility)
    except TrnexeLaunchError as e:
      stderr.writeLine("Error: ", e.msg)
      eventSink(statusEvent(simFatal.status))
      return simFatal
    startTime = getTime()

    let waitStatus = waitReady(
      process = process,
      deckFile = deckFile,
      waitForGui = settings.waitForGui,
      waitForLst = settings.waitForLst,
      waitForTmp = settings.waitForTmp,
      timeoutMs = settings.detectTimeoutMs,
      extraDelayMs = settings.extraDelayMs,
    )

    case waitStatus
    of wrDied:
      if process.running:
        process.kill()
        eventSink(statusEvent(simFatal.status))
        return simFatal
    of wrTimeout:
      if process.running and settings.killOnTimeout:
        process.kill()
        eventSink(statusEvent(simTimeout.status))
        return simTimeout
    else:
      discard

    if settings.guiVisibility.wantsMinimize() and process.running:
      discard minimizeGui(process)

    eventSink(statusEvent(statusRunning))

  let monitorResult = monitor(
    process = process,
    deckFile = deckFile,
    startTime = startTime,
    eventSink = eventSink,
    watchLog = settings.watchLog,
    watchTmp = settings.watchTmp,
    pollMs = settings.pollMs,
    severity = settings.severity,
    watchTimeoutMs = settings.watchTimeoutMs,
    stallTimeoutMs = settings.stallTimeoutMs,
  )

  case monitorResult
  of simDone:
    eventSink(statusEvent(monitorResult.status))
    if settings.cleanOnSuccess:
      unlinkFiles(deckFile)
  of simFatal, simCancelled:
    eventSink(statusEvent(monitorResult.status))
  of simStalled:
    if process.running and settings.killOnStall:
      process.kill()

    eventSink(statusEvent(monitorResult.status))

    if process.running and not settings.killOnStall:
      discard process.waitForExit()
  of simTimeout:
    if process.running and settings.killOnTimeout:
      process.kill()

    eventSink(statusEvent(monitorResult.status))

    if process.running and not settings.killOnTimeout:
      discard process.waitForExit()

  return monitorResult

# Direct-run example
when isMainModule:
  let deckFile = absolutePath(r"examples\dck\example_w_plot_w_tracking.dck")
  var runnerSettings = DefaultRunnerSettings
  runnerSettings.guiVisibility = guiMinimizedAuto

  let simResult = simulate(
    deckFile = deckFile,
    eventSink = stdoutEventSink(),
    settings = runnerSettings,
  )
  stderr.writeLine(fmt"Simulation finished with result: {simResult}")
