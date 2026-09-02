## Orchestrates the complete TRNSYS simulation lifecycle.
##
## Validates inputs, guards process lifetime, serializes TrnEXE launch, waits
## for readiness, monitors output, emits structured events, handles terminal
## outcomes, and performs optional cleanup.

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
import ./validate
import ./wait

proc runSimulation*(
    deckFile: string,
    eventSink: EventSink,
    settings: RunnerSettings = DefaultRunnerSettings,
): SimResult =
  ## Validates and runs one simulation, reporting through `eventSink`.
  ##
  ## Emits `SETTING` first, followed by lifecycle `STATUS` transitions and the
  ## enabled `CONFIG`, `PROGRESS`, and `LOG` events. Every failure reaches the
  ## caller as a terminal event plus a result rather than as an exception:
  ## `simInvalid` for a rejected deck or TrnEXE path, `simFatal` for the rest.
  var settings = settings.normalized()

  var deck = ""
  try:
    deck = validateDeck(deckFile)
    settings.trnexePath = validateTrnexe(settings.trnexePath)
  except IOError, ValueError:
    eventSink(statusEvent(simInvalid.status, message = getCurrentExceptionMsg()))
    return simInvalid

  try:
    initJobGuard()
  except OSError as error:
    eventSink(statusEvent(simFatal.status, message = "Orphan guard unavailable: " & error.msg))
    return simFatal

  eventSink(settingEvent(settings, settings.trnexePath))
  eventSink(statusEvent(statusPending))

  var
    process: Process = default(Process)
    startTime: MonoTime = default(MonoTime)

  defer:
    # Handle cleanup only: the outcome is already reported, so a failure here
    # has nothing left to contradict it with.
    try:
      if process != nil:
        process.close()
    except CatchableError:
      discard

  try:
    withLaunchLock:
      eventSink(statusEvent(statusLaunching))
      if not removeSidecarFiles(deck):
        eventSink(statusEvent(simFatal.status, message = "Could not delete one or more sidecar files"))
        return simFatal

      process = launchTrnexe(deck, settings.trnexePath, settings.guiVisibility)
      startTime = getMonoTime()

      case waitReady(
        process = process,
        deckFile = deck,
        waitForGui = settings.waitForGui,
        waitForLst = settings.waitForLst,
        waitForTmp = settings.waitForTmp,
        timeoutMs = settings.detectTimeoutMs,
        extraDelayMs = settings.extraDelayMs,
      )
      of wrReady:
        discard
      of wrExited:
        # Not a failure by itself: the run may simply have finished before
        # detection did. The monitor below drains the log and reports simFatal
        # if TRNSYS actually logged one.
        if process.running:
          # Contradicts wrExited, so the state is unrecoverable rather than fast.
          # A kill that fails must not replace the outcome being reported.
          try:
            process.kill()
          except OSError:
            discard
          eventSink(statusEvent(simFatal.status, message = "TRNSYS reported process exit but remained running"))
          return simFatal
      of wrTimeout:
        if process.running and settings.killOnTimeout:
          try:
            process.kill()
          except OSError:
            discard
          eventSink(statusEvent(simTimeout.status, message = "TRNSYS readiness detection timed out"))
          return simTimeout

      if settings.guiVisibility.wantsMinimize() and process.running:
        discard minimizeGui(process)

      eventSink(statusEvent(statusRunning))

    let outcome = monitor(
      process = process,
      deckFile = deck,
      startTime = startTime,
      eventSink = eventSink,
      watchLog = settings.watchLog,
      watchTmp = settings.watchTmp,
      pollMs = settings.pollMs,
      severity = settings.severity,
      watchTimeoutMs = settings.watchTimeoutMs,
      stallTimeoutMs = settings.stallTimeoutMs,
    )

    # A stall or a timeout is the only way out that can leave the process
    # alive: either we end it, or we let it finish on its own.
    let killProcess =
      case outcome
      of simStalled: settings.killOnStall
      of simTimeout: settings.killOnTimeout
      else: false
    if killProcess and process.running:
      try:
        process.kill()
      except OSError:
        discard

    var message = ""
    if outcome == simDone and settings.cleanOnSuccess and
        not removeSidecarFiles(deck):
      message =
        "Simulation completed, but one or more sidecar files could not be removed"
    eventSink(statusEvent(outcome.status, message = message))

    if not killProcess and outcome in {simStalled, simTimeout}:
      discard process.waitForExit()

    return outcome
  except CatchableError:
    # Launch, mutex, readiness, and monitoring failures all land here: the
    # process must not outlive the run that can no longer report on it.
    try:
      if process != nil and process.running:
        process.kill()
    except OSError:
      discard
    eventSink(statusEvent(simFatal.status, message = getCurrentExceptionMsg()))
    return simFatal

proc simulate*(
    deckFile: string,
    settings: RunnerSettings = DefaultRunnerSettings,
    runId: string = "",
): SimResult =
  ## Runs one simulation, reporting to stdout and an optional JSONL file.
  ## When non-empty, `runId` is attached to every emitted event.
  ##
  ## Each call owns a deck-specific JSONL writer and an independent event sink,
  ## so repeated calls produce separate event files and sequences.
  ##
  ## The file mirror is attached only once the deck path resolves, since the
  ## deck names both the run and its event file: a rejected deck reports
  ## `ERROR` on stdout without leaving a file behind. The file therefore either
  ## does not exist, or holds the whole stream.
  var settings = settings

  let
    jsonlOutput = newJsonlWriter()
    eventSink = stdoutEventSink(jsonlOutput, runId)
  defer:
    jsonlOutput.close()

  try:
    jsonlOutput.attachEventFile(validateDeck(deckFile), settings.writeEvents)
  except IOError, ValueError:
    discard # runSimulation re-validates and reports this as a terminal event.

  return runSimulation(deckFile, eventSink, settings)

# Direct-run example
when isMainModule:
  let deckFile = absolutePath(
    r"trnrun\examples\dck\example_w_plot_w_tracking.dck"
  )
  var runnerSettings = DefaultRunnerSettings
  runnerSettings.guiVisibility = guiMinimizedAuto

  let simResult = simulate(deckFile, runnerSettings)
  stderr.writeLine(fmt"Simulation finished with result: {simResult}")
