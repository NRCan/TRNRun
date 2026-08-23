## Orchestrates the complete TRNSYS simulation lifecycle.
##
## Validates inputs, guards process lifetime, serializes TrnEXE launch, waits
## for readiness, monitors output, emits structured events, handles terminal
## outcomes, and performs optional cleanup.

import std/[monotimes, os, osproc, strformat, strutils]
import ./events
import ./eventsink
import ./job
import ./monitor
import ./mutex
import ./settings
import ./status
import ./wait

# Types and constants
type
  TrnexeLaunchError = object of CatchableError
    ## Raised when TrnEXE fails to start.

const
  SidecarExtensions = [
    ".tmp", # Temporary progress file
    ".log", # Simulation log containing notices, warnings, and fatal errors
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
    raise newException(
      ValueError, fmt"Expected .dck or .trd, got: '{deckFile}'"
    )

proc validateTrnexe*(trnexePath: string): string =
  ## Resolves the TRNSYS executable to an absolute, normalized path.
  ## Raises `IOError` if it does not exist.
  result = trnexePath.absolutePath().normalizedPath()
  if not fileExists(result):
    raise newException(IOError, fmt"TRNEXE not found: '{result}'")

# Process launch
proc launchTrnexe(
    deckFile: string,
    trnexePath: string,
    guiVisibility: TrnexeGuiVisibility,
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
      trnexePath,
      workingDir = deckFile.parentDir(),
      args = args,
      options = {},
    )
  except OSError, IOError:
    raise newException(
      TrnexeLaunchError,
      "Failed to launch TRNSYS: " & getCurrentExceptionMsg(),
    )

proc removeSidecarFiles(deckFile: string) =
  ## Deletes TRNSYS sidecar files for a deck, ignoring missing ones.
  for extension in SidecarExtensions:
    let sidecarPath = deckFile.changeFileExt(extension)
    if not tryRemoveFile(sidecarPath):
      stderr.writeLine(fmt"Warning: Could not delete {sidecarPath} (likely in use).")

# Simulation
proc simulate*(
    deckFile: string,
    eventSink: EventSink,
    settings: RunnerSettings = DefaultRunnerSettings,
): SimResult =
  ## Runs one TRNSYS simulation and returns its final outcome.
  ##
  ## Emits `SETTING` first, followed by lifecycle `STATUS` transitions and
  ## enabled `CONFIG`, `PROGRESS`, and `LOG` events. Launch, readiness,
  ## monitoring, timeout, stall, process-termination, and cleanup decisions
  ## remain within this lifecycle boundary.
  ##
  ## Missing files raise `IOError`, and an unsupported deck extension raises
  ## `ValueError`. TrnEXE launch failures are converted to `simFatal` after
  ## emitting the terminal status event.
  let deckFile = validateDeck(deckFile)
  let trnexePath = validateTrnexe(settings.trnexePath)

  try:
    initJobGuard()
  except OSError as error:
    stderr.writeLine(
      "Warning: orphan guard unavailable, TrnEXE64.exe may outlive trnrun: ",
      error.msg,
    )

  eventSink(settingEvent(settings, trnexePath))
  eventSink(statusEvent(statusPending))

  var
    process: Process = default(Process)
    startTime: MonoTime = default(MonoTime)

  defer:
    if process != nil:
      try:
        process.close()
      except CatchableError:
        discard

  withLaunchLock:
    removeSidecarFiles(deckFile)
    eventSink(statusEvent(statusLaunching))

    try:
      process = launchTrnexe(deckFile, trnexePath, settings.guiVisibility)
    except TrnexeLaunchError as error:
      stderr.writeLine("Error: ", error.msg)
      eventSink(statusEvent(simFatal.status))
      return simFatal
    startTime = getMonoTime()

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
    of wrReady:
      discard
    of wrExited:
      # Not a failure by itself: the run may simply have finished before
      # detection did. The monitor below drains the log and reports simFatal
      # if TRNSYS actually logged one.
      if process.running:
        # Contradicts wrExited, so the state is unrecoverable rather than fast.
        process.kill()
        eventSink(statusEvent(simFatal.status))
        return simFatal
    of wrTimeout:
      if process.running and settings.killOnTimeout:
        process.kill()
        eventSink(statusEvent(simTimeout.status))
        return simTimeout

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

  var
    shouldKillProcess = false
    shouldWaitForProcess = false

  case monitorResult
  of simDone, simFatal, simCancelled:
    discard

  of simStalled:
    shouldKillProcess = settings.killOnStall
    shouldWaitForProcess = not shouldKillProcess

  of simTimeout:
    shouldKillProcess = settings.killOnTimeout
    shouldWaitForProcess = not shouldKillProcess

  if process.running and shouldKillProcess:
    process.kill()

  eventSink(statusEvent(monitorResult.status))

  if process.running and shouldWaitForProcess:
    discard process.waitForExit()

  if monitorResult == simDone and settings.cleanOnSuccess:
    removeSidecarFiles(deckFile)

  return monitorResult

# Direct-run example
when isMainModule:
  let deckFile = absolutePath(
    r"runner\examples\dck\example_w_plot_w_tracking.dck"
  )
  var runnerSettings = DefaultRunnerSettings
  runnerSettings.guiVisibility = guiMinimizedAuto

  let simResult = simulate(
    deckFile = deckFile,
    eventSink = stdoutEventSink(),
    settings = runnerSettings,
  )
  stderr.writeLine(fmt"Simulation finished with result: {simResult}")
