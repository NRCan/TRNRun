## This module provides a high-level interface for launching, monitoring,
## and managing TRNSYS simulations via TrnEXE. It wraps process execution,
## readiness detection, and runtime monitoring into a single controlled
## workflow with structured status reporting.
##
## Key features:
## - Safe execution of TRNSYS decks (.dck / .trd)
## - Automatic validation of inputs and executable paths
## - Global execution locking to prevent concurrent conflicts
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

  TrnexeGuiVisibility* = enum
    guiKeepOpen = ""
    guiAutoClose = "/n"
    guiHidden = "/h"

  SimStatus* = enum
    statusPending = "PENDING"
    statusLaunching = "LAUNCHING"
    statusRunning = "RUNNING"
    statusDone = "DONE"
    statusCancelled = "CANCELLED"
    statusError = "ERROR"
    statusTimeout = "TIMEOUT"
    statusStalled = "STALLED"

const
  DefaultTrnexePath* = r"C:\TRNSYS18\Exe\TrnEXE64.exe"
  DefaultGuiVisibility* = guiHidden
  Extensions = [".tmp", ".log", ".lst"]

# ---------------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------------
const IsoFmt: string = "yyyy-MM-dd'T'HH:mm:ss"

proc toJson*(status: SimStatus): JsonNode =
  result = newJObject()
  result["kind"] = %"STATUS"
  result["timestamp"] = %now().format(IsoFmt)
  result["status"] = %($status)

proc emit(status: SimStatus, jsonlPath: string = "") =
  let line = $status.toJson()
  echo line
  stdout.flushFile()

  if jsonlPath.len > 0:
    let f = open(jsonlPath, fmAppend)
    f.writeLine(line)
    f.close()

# ---------------------------------------------------------------------------
# Validation & file helpers
# ---------------------------------------------------------------------------
proc validateDeck*(deckFile: string) =
  if not fileExists(deckFile):
    raise newException(IOError, fmt"Deck file not found: '{deckFile}'")
  if deckFile.splitFile().ext.toLowerAscii() notin [".dck", ".trd"]:
    raise newException(ValueError, fmt"Expected .dck or .trd, got: '{deckFile}'")

proc validateTrnexe*(trnexePath: string) =
  if not fileExists(trnexePath):
    raise newException(IOError, fmt"TRNEXE not found: '{trnexePath}'")

# ---------------------------------------------------------------------------
# Launch TRNSYS
# ---------------------------------------------------------------------------
proc launchTrnexe*(
    deckFile: string,
    trnexePath: string = DefaultTrnexePath,
    guiVisibility: TrnexeGuiVisibility = DefaultGuiVisibility,
): Process =
  ## Spawns TrnEXE and returns the process.
  var args = @[deckFile]
  if guiVisibility != guiKeepOpen:
    args.add($guiVisibility)

  try:
    return startProcess(
      trnexePath, workingDir = deckFile.parentDir(), args = args, options = {}
    )
  except OSError, IOError:
    raise newException(
      TrnexeLaunchError, "Failed to launch TRNSYS: " & getCurrentExceptionMsg()
    )

proc unlinkFiles*(deckFile: string) =
  ## Deletes TRNSYS sidecar files for a given deck, ignoring missing files.
  for ext in Extensions:
    let f = deckFile.changeFileExt(ext)
    if fileExists(f) and not tryRemoveFile(f):
      echo fmt"Warning: Could not delete {f} (likely in use)."

proc unlinkJsonl*(deckFile: string) =
  let f = deckFile.changeFileExt("jsonl")
  if fileExists(f) and not tryRemoveFile(f):
    echo fmt"Warning: Could not delete {f} (likely in use)."

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
  ## Launches and monitors a TRNSYS simulation, streaming structured JSON status
  ## and optional log events.
  ##
  ## The procedure validates the deck and TRNSYS executable, acquires a global
  ## execution lock, launches TrnEXE, and waits for readiness signals (GUI,
  ## `.lst`, or `.tmp`). Once ready, it continuously monitors the running
  ## simulation until completion, failure, cancellation, timeout, or stall.
  ##
  ## A JSON status stream is printed to stdout for each state transition, and
  ## optionally written to a JSONL file located at:
  ##   `<deckFile>.jsonl` (only if `writeLog = true`).
  ##
  ## Execution phases:
  ## - VALIDATION: deck and executable existence/type checks
  ## - LAUNCHING: TRNSYS process is started
  ## - READINESS: waits for GUI/.lst/.tmp signals (`waitReady`)
  ## - RUNNING: simulation is actively monitored
  ## - TERMINATION: normal exit, timeout, stall, fatal error, or cancellation
  ##
  ## Parameters:
  ## - `deckFile`        - Path to `.dck` or `.trd` simulation deck.
  ## - `trnexePath`      - Path to TRNSYS executable (TrnEXE64.exe).
  ## - `guiVisibility`   - Controls GUI behavior (`keep open`, `auto close`, `hidden`).
  ## - `waitForGui`       - Use GUI window presence as readiness signal.
  ## - `waitForLst`       - Wait for `.lst` file generation as readiness signal.
  ## - `waitForTmp`       - Wait for `.tmp` file as readiness signal.
  ## - `detectTimeoutMs` - Max time to wait for readiness before timeout.
  ## - `extraDelayMs`    - Delay after launch before readiness checks begin.
  ## - `watchLog`        - Stream `.log` output as structured events.
  ## - `watchTmp`        - Stream `.tmp` updates (progress/config events).
  ## - `watchTimeoutMs`  - Max monitoring duration (0 = unlimited).
  ## - `stallTimeoutMs`  - Max time simulation time may go without advancing,
  ##                       before being reported as stalled (0 = disabled).
  ##                       Requires `watchTmp = true` to have any effect.
  ## - `pollMs`          - Polling interval for file/process monitoring.
  ## - `cleanOnSuccess`  - Delete TRNSYS sidecar files on successful completion.
  ## - `killOnTimeout`   - Kill TRNSYS process if a watch timeout occurs.
  ## - `killOnStall`     - Kill TRNSYS process if a stall is detected.
  ## - `severity`        - Minimum log severity level to emit.
  ## - `writeLog`        - Enable writing JSONL output to `<deckFile>.jsonl`.
  ##
  ## Returns:
  ## - `SimMonitorResult` describing final simulation outcome:
  ##   - `monitorDone`     - Completed successfully
  ##   - `monitorFatal`    - Process crashed or failed
  ##   - `monitorCancelled`- Manually cancelled
  ##   - `monitorTimeout`  - Watch timeout reached
  ##   - `monitorStalled`  - Simulation time stopped advancing
  validateDeck(deckFile)
  validateTrnexe(trnexePath)

  let jsonlPath: string =
    if writeLog:
      deckFile.changeFileExt("jsonl")
    else:
      ""
  unlinkJsonl(deckFile)
  emit(statusPending, jsonlPath)

  var process: Process
  var startTime: Time

  withLock:
    unlinkFiles(deckFile)
    emit(statusLaunching, jsonlPath)

    try:
      process = launchTrnexe(deckFile, trnexePath, guiVisibility)
    except TrnexeLaunchError:
      emit(statusError, jsonlPath)
      return monitorFatal
    assignToJob(process)
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
  const DeckFile =
    r"C:\Users\alexl\Documents\Project\Coding\TRNRun\examples\data\dck\example_slow_wo_plot_w_tracking_2.dck"

  let simResult = simulate(deckFile = DeckFile, extraDelayMs = 0, waitForTmp = true)
  echo fmt"Simulation finished with result: {simResult}"
