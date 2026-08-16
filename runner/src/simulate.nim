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
## - Structured JSON status output (stdout + optional JSONL file)
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
## - Always emits JSON status events to stdout
## - Optionally writes a JSONL log per simulation:
##     `<deckFile>.jsonl` (if writeLog = true)

import std/[os, osproc, strformat, strutils, times, json]
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

  SimStatus* = enum
    ## Lifecycle states emitted as `STATUS` events.
    statusPending = "PENDING"
    statusLaunching = "LAUNCHING"
    statusRunning = "RUNNING"
    statusDone = "DONE"
    statusCancelled = "CANCELLED"
    statusError = "ERROR"
    statusTimeout = "TIMEOUT"
    statusStalled = "STALLED"

const
  DefaultTrnexePath* = r"C:\TRNSYS18\Exe\TrnEXE64.exe" # Default TRNSYS 18 executable path.
  DefaultGuiVisibility* = guiHidden # GUI mode used when none is specified.
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
# Status
# ---------------------------------------------------------------------------
const IsoFmt: string = "yyyy-MM-dd'T'HH:mm:ss"

proc toJson*(status: SimStatus): JsonNode =
  ## Serialises a status transition as a `STATUS` event.
  result = newJObject()
  result["kind"] = %"STATUS"
  result["timestamp"] = %now().format(IsoFmt)
  result["status"] = %($status)

proc emit(status: SimStatus, jsonlPath: string = "") =
  ## Writes a status event to stdout and the JSONL file, flushing immediately.
  let line = $status.toJson()
  echo line
  stdout.flushFile()
  appendJsonl(jsonlPath, line)

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

proc unlinkJsonl*(deckFile: string) =
  ## Deletes the deck's `.jsonl` event file if present.
  let f = deckFile.changeFileExt("jsonl")
  if fileExists(f) and not tryRemoveFile(f):
    stderr.writeLine(fmt"Warning: Could not delete {f} (likely in use).")

# ---------------------------------------------------------------------------
# Main simulation
# ---------------------------------------------------------------------------
proc simulate*(
    deckFile: string,
    trnexePath: string = DefaultTrnexePath,
    guiVisibility: TrnexeGuiVisibility = DefaultGuiVisibility,
    waitForGui: bool = true,
    waitForLst: bool = true,
    waitForTmp: bool = false,
    detectTimeoutMs: int = 0,
    extraDelayMs: int = 0,
    watchLog: bool = true,
    watchTmp: bool = true,
    watchTimeoutMs: int = 0,
    stallTimeoutMs: int = 0,
    pollMs: int = 100,
    cleanOnSuccess: bool = false,
    killOnTimeout: bool = false,
    killOnStall: bool = true,
    severity: LogSeverity = Notice,
    writeLog: bool = true,
): SimMonitorResult =
  ## Launches and monitors a TRNSYS simulation, streaming structured JSON events.
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
  ## trnexePath : string, optional
  ##     Path to the TRNSYS executable (default: `DefaultTrnexePath`).
  ## guiVisibility : TrnexeGuiVisibility, optional
  ##     GUI mode. The minimized modes are synthesized once after launch via
  ##     Win32; plotter windows TRNSYS opens later in the run are not
  ##     re-minimized (default: `DefaultGuiVisibility`).
  ## waitForGui : bool, optional
  ##     Treat the appearance of a TRNSYS window as a readiness signal
  ##     (default: true).
  ## waitForLst : bool, optional
  ##     Wait for the `.lst` component-order header (default: true).
  ## waitForTmp : bool, optional
  ##     Wait for the `.tmp` file to appear (default: false).
  ## detectTimeoutMs : int, optional
  ##     Shared timeout across all readiness stages; 0 = unlimited
  ##     (default: 0).
  ## extraDelayMs : int, optional
  ##     Additional delay after readiness before monitoring starts
  ##     (default: 0).
  ## watchLog : bool, optional
  ##     Stream `.log` entries as `LOG` events (default: true).
  ## watchTmp : bool, optional
  ##     Stream `.tmp` updates as `CONFIG`/`PROGRESS` events (default: true).
  ## watchTimeoutMs : int, optional
  ##     Maximum monitoring duration in ms; 0 = unlimited (default: 0).
  ## stallTimeoutMs : int, optional
  ##     Maximum time simulation time may go without advancing before the
  ##     run is reported as stalled; 0 = disabled, requires `watchTmp`
  ##     (default: 0).
  ## pollMs : int, optional
  ##     Polling interval for file and process monitoring (default: 100).
  ## cleanOnSuccess : bool, optional
  ##     Delete TRNSYS sidecar files after a successful run (default: false).
  ## killOnTimeout : bool, optional
  ##     Kill the TRNSYS process when a readiness or watch timeout occurs
  ##     (default: false).
  ## killOnStall : bool, optional
  ##     Kill the TRNSYS process when a stall is detected (default: true).
  ## severity : LogSeverity, optional
  ##     Minimum log severity level to emit (default: Notice).
  ## writeLog : bool, optional
  ##     Also append every event to `<deckFile>.jsonl` (default: true).
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
  let trnexePath = validateTrnexe(trnexePath)

  try:
    initJobGuard()
  except OSError as e:
    stderr.writeLine("Warning: orphan guard unavailable, TrnEXE64.exe may outlive trnrun: ", e.msg)

  let jsonlPath: string =
    if writeLog:
      deckFile.changeFileExt("jsonl")
    else:
      ""
  unlinkJsonl(deckFile)
  emit(statusPending, jsonlPath)

  var process: Process = default(Process)
  var startTime: Time = default(Time)

  withLaunchLock:
    unlinkFiles(deckFile)
    emit(statusLaunching, jsonlPath)

    try:
      process = launchTrnexe(deckFile, trnexePath, guiVisibility)
    except TrnexeLaunchError:
      emit(statusError, jsonlPath)
      return monitorFatal
    startTime = getTime()

    let waitStatus = waitReady(
      process = process,
      deckFile = deckFile,
      waitForGui = waitForGui,
      waitForLst = waitForLst,
      waitForTmp = waitForTmp,
      timeoutMs = detectTimeoutMs,
      extraDelayMs = extraDelayMs,
    )

    case waitStatus
    of wrDied:
      if process.running:
        process.kill()
        emit(statusError, jsonlPath)
        return monitorFatal
    of wrTimeout:
      if process.running and killOnTimeout:
        process.kill()
        emit(statusTimeout, jsonlPath)
        return monitorTimeout
    else:
      discard

    if guiVisibility.wantsMinimize() and process.running:
      discard minimizeGui(process)

    emit(statusRunning, jsonlPath)

  let monitorResult = monitor(
    process = process,
    deckFile = deckFile,
    startTime = startTime,
    watchLog = watchLog,
    watchTmp = watchTmp,
    pollMs = pollMs,
    severity = severity,
    watchTimeoutMs = watchTimeoutMs,
    stallTimeoutMs = stallTimeoutMs,
    jsonlPath = jsonlPath,
  )

  case monitorResult
  of monitorDone:
    emit(statusDone, jsonlPath)
    if cleanOnSuccess:
      unlinkFiles(deckFile)
  of monitorFatal:
    emit(statusError, jsonlPath)
  of monitorCancelled:
    emit(statusCancelled, jsonlPath)
  of monitorStalled:
    if process.running and killOnStall:
      process.kill()

    emit(statusStalled, jsonlPath)

    if process.running and not killOnStall:
      discard process.waitForExit()
  of monitorTimeout:
    if process.running and killOnTimeout:
      process.kill()

    emit(statusTimeout, jsonlPath)

    if process.running and not killOnTimeout:
      discard process.waitForExit()

  return monitorResult

# ---------------------------------------------------------------------------
when isMainModule:
  let deckFile = absolutePath(r"examples\dck\example_w_plot_w_tracking.dck")

  let simResult = simulate(
    deckFile = deckFile,
    guiVisibility = guiMinimizedAuto,
    extraDelayMs = 0,
    waitForTmp = false,
    waitForGui = true,
  )
  echo fmt"Simulation finished with result: {simResult}"
