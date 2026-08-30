## Orchestrates the complete TRNSYS simulation lifecycle.
##
## Guards process lifetime, serializes TrnEXE launch, waits for readiness,
## monitors output, emits structured events, handles terminal outcomes, and
## performs optional cleanup.

import std/[monotimes, osproc]
when isMainModule:
  import std/[os, strformat]

import ./events
import ./eventsink
import ./job
import ./monitor
import ./mutex
import ./settings
import ./sidecar
import ./status
import ./trnexe
import ./wait

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
  ## File inputs must be resolved and validated by the caller. TrnEXE launch
  ## failures are converted to `simFatal` after emitting the terminal status
  ## event.
  let settings = settings.normalized()
  let trnexePath = settings.trnexePath

  try:
    initJobGuard()
  except OSError as error:
    stderr.writeLine("Warning: orphan guard unavailable, TrnEXE64.exe may outlive trnrun: ",error.msg)

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
    eventSink(statusEvent(statusLaunching))
    if not removeSidecarFiles(deckFile):
      eventSink(statusEvent(
        simFatal.status,
        message = "Could not delete one or more sidecar files",
      ))
      return simFatal

    try:
      process = launchTrnexe(deckFile, trnexePath, settings.guiVisibility)
    except TrnexeLaunchError as error:
      eventSink(statusEvent(simFatal.status, message = error.msg))
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
        eventSink(statusEvent(
          simFatal.status,
          message = "TRNSYS reported process exit but remained running",
        ))
        return simFatal
    of wrTimeout:
      if process.running and settings.killOnTimeout:
        process.kill()
        eventSink(statusEvent(
          simTimeout.status,
          message = "TRNSYS readiness detection timed out",
        ))
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

  var terminalMessage = ""
  if monitorResult == simDone and settings.cleanOnSuccess and
      not removeSidecarFiles(deckFile):
    terminalMessage =
      "Simulation completed, but one or more sidecar files could not be removed"

  eventSink(statusEvent(monitorResult.status, message = terminalMessage))

  if process.running and shouldWaitForProcess:
    discard process.waitForExit()

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
