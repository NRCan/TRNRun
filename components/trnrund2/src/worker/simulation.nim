## Defines one simulation's record and how TRNRun events and exits update it.
##
## Timestamps are UTC ISO 8601 text with milliseconds, such as
## `2026-10-09T14:03:12.345Z`, which sort chronologically as text.

import std/[options, times]
import ./events

export events

type
  SimulationState* = enum
    ## Simulation lifecycle, separate from TRNRun's status. Values are part of the wire protocol.
    ssQueued = "QUEUED" ## Waiting for a free worker.
    ssRunning = "RUNNING" ## TRNRun started.
    ssFinished = "FINISHED" ## Completed, failed or cancelled; see `succeeded`.

  Simulation* = object
    ## One simulation; a value TRNRun has not reported yet is none.
    simId*: int
    label*: Option[string]
    state*: SimulationState
    trnrunStatus*: Option[SimStatus]
    trnrunMessage*: Option[string]
    percent*, simTime*, elapsedMs*, etaMs*: Option[float]
    notices*, warnings*, fatals*: int
    succeeded*: Option[bool] ## Set once `FINISHED`.
    exitCode*: Option[int]
    error*: Option[string]
    submittedAt*: string
    startedAt*, finishedAt*: Option[string]
    deckFile*: string
    trnrunArgs*: seq[string]
    startTime*, stopTime*, timeStep*: Option[float]
    setting*: Option[SettingEvent]
    logs*: seq[LogEvent] ## Oldest first.

const
  TerminalStatuses = {stDone, stCancelled, stError, stTimeout, stStalled}
  CancelReason = "cancelled by the client"

proc timestamp(): string =
  ## The current time, as every timestamp is kept.
  now().utc().format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc initSimulation*(
    simId: int,
    deckFile: string,
    trnrunArgs: seq[string],
    label: Option[string],
): Simulation =
  ## A new `QUEUED` simulation, submitted now.
  Simulation(
    simId: simId,
    label: label,
    state: ssQueued,
    submittedAt: timestamp(),
    deckFile: deckFile,
    trnrunArgs: trnrunArgs,
  )

proc start*(simulation: var Simulation) =
  ## Marks the simulation running once its TRNRun has started.
  simulation.state = ssRunning
  simulation.startedAt = some(timestamp())

proc record*(simulation: var Simulation, event: SimulationEvent) =
  ## Saves one TRNRun event: a `LOG` is counted and appended, any other replaces the last value.
  case event.kind
  of ekSetting:
    simulation.setting = some(event.setting)
  of ekStatus:
    simulation.trnrunStatus = some(event.status.status)
    simulation.trnrunMessage = some(event.status.message)
  of ekConfig:
    simulation.startTime = some(event.config.start)
    simulation.stopTime = some(event.config.stop)
    simulation.timeStep = some(event.config.step)
  of ekProgress:
    simulation.percent = some(event.progress.percent)
    simulation.simTime = some(event.progress.time)
    simulation.elapsedMs = some(event.progress.elapsedMs)
    simulation.etaMs = some(event.progress.etaMs)
  of ekLog:
    case event.log.severity
    of lsNotice: inc simulation.notices
    of lsWarning: inc simulation.warnings
    of lsFatal: inc simulation.fatals
    simulation.logs.add(event.log)

proc recordLine*(simulation: var Simulation, line: string) =
  ## Saves the TRNRun event in one output line; ignores a line that is not one.
  let event = parseEventLine(line)
  if event.isSome:
    simulation.record(event.get())

proc finish(
    simulation: var Simulation,
    exitCode: Option[int],
    error: string,
    fallback: StatusEvent,
) =
  ## Marks the simulation finished, with `fallback` as its status unless TRNRun reported an end.
  if simulation.trnrunStatus.isNone or simulation.trnrunStatus.get() notin TerminalStatuses:
    simulation.trnrunStatus = some(fallback.status)
    simulation.trnrunMessage = some(fallback.message)
  # It succeeded only with a `DONE` status from TRNRun, exit code 0, and no daemon error.
  simulation.succeeded = some(
    simulation.trnrunStatus == some(stDone) and exitCode == some(0) and error.len == 0
  )
  simulation.state = ssFinished
  simulation.finishedAt = some(timestamp())
  simulation.exitCode = exitCode
  simulation.error = if error.len > 0: some(error) else: none(string)

proc finish*(simulation: var Simulation, exitCode: Option[int], error: string = "") =
  ## Marks the simulation finished once TRNRun exited or failed to start; `ERROR` if it reported no end.
  let message = if error.len > 0: error else: "TRNRun exited without a terminal status"
  simulation.finish(exitCode, error, StatusEvent(status: stError, message: message))

proc cancel*(simulation: var Simulation) =
  ## Finishes the simulation as `CANCELLED`, interrupted if it was running.
  let outcome = if simulation.state == ssRunning: "Interrupted" else: "Not started"
  simulation.finish(
    exitCode = none(int),
    error = outcome & ": " & CancelReason,
    fallback = StatusEvent(status: stCancelled, message: outcome),
  )
