## Defines one simulation's record and how TRNRun events and exits update it.
##
## Timestamps are UTC ISO 8601 text with milliseconds, such as
## `2026-10-09T14:03:12.345Z`, which sort chronologically as text.

import std/[json, options, times]
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
    trnrunOptions*: JsonNode ## As the client sent them; an object, empty when none.
    startTime*, stopTime*, timeStep*: Option[float]
    setting*: Option[SettingEvent]
    logs*: seq[LogEvent] ## Oldest first.

const
  TerminalStatuses = {stDone, stCancelled, stError, stTimeout, stStalled}
  CancelReason = "cancelled by the client"

proc timestamp(): string =
  ## The current time, as every timestamp is kept.
  return now().utc().format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

proc initSimulation*(
    simId: int,
    deckFile: sink string,
    trnrunOptions: JsonNode,
    label: sink Option[string],
): Simulation =
  ## A new `QUEUED` simulation, submitted now.
  return Simulation(
    simId: simId,
    label: label,
    state: ssQueued,
    submittedAt: timestamp(),
    deckFile: deckFile,
    trnrunOptions: trnrunOptions,
  )

proc start*(self: var Simulation) =
  ## Marks the simulation running once its TRNRun has started.
  self.state = ssRunning
  self.startedAt = some(timestamp())

proc record*(self: var Simulation, event: SimulationEvent) =
  ## Saves one TRNRun event: a `LOG` is counted and appended, any other replaces the last value.
  case event.kind
  of ekSetting:
    self.setting = some(event.setting)
  of ekStatus:
    self.trnrunStatus = some(event.status.status)
    self.trnrunMessage = some(event.status.message)
  of ekConfig:
    self.startTime = some(event.config.start)
    self.stopTime = some(event.config.stop)
    self.timeStep = some(event.config.step)
  of ekProgress:
    self.percent = some(event.progress.percent)
    self.simTime = some(event.progress.time)
    self.elapsedMs = some(event.progress.elapsedMs)
    self.etaMs = some(event.progress.etaMs)
  of ekLog:
    case event.log.severity
    of lsNotice: inc self.notices
    of lsWarning: inc self.warnings
    of lsFatal: inc self.fatals
    self.logs.add(event.log)

proc recordLines*(self: var Simulation, lines: seq[string]) =
  ## Saves the TRNRun event in each output line; ignores a line that is not one.
  for line in lines:
    let event = parseEventLine(line)
    if event.isSome:
      self.record(event.get())

proc finish(
    self: var Simulation,
    exitCode: Option[int],
    error: string,
    fallback: StatusEvent,
) =
  ## Marks the simulation finished, with `fallback` as its status unless TRNRun reported an end.
  if self.trnrunStatus.isNone or self.trnrunStatus.get() notin TerminalStatuses:
    self.trnrunStatus = some(fallback.status)
    self.trnrunMessage = some(fallback.message)
  # It succeeded only with a `DONE` status from TRNRun, exit code 0, and no daemon error.
  self.succeeded = some(
    self.trnrunStatus == some(stDone) and exitCode == some(0) and error.len == 0
  )
  self.state = ssFinished
  self.finishedAt = some(timestamp())
  self.exitCode = exitCode
  self.error = if error.len > 0: some(error) else: none(string)

proc finish*(self: var Simulation, exitCode: Option[int], error: string = "") =
  ## Finishes the simulation once TRNRun exited or failed to start.
  ##
  ## `exitCode` is none if TRNRun never started, and `error` explains why. If
  ## TRNRun reported no terminal status, the status becomes `ERROR`. The
  ## simulation succeeded only with status `DONE`, exit code 0 and no `error`.
  let message = if error.len > 0: error else: "TRNRun exited without a terminal status"
  self.finish(exitCode, error, StatusEvent(status: stError, message: message))

proc cancel*(self: var Simulation) =
  ## Finishes the simulation as `CANCELLED`, interrupted if it was running.
  let outcome = if self.state == ssRunning: "Interrupted" else: "Not started"
  self.finish(
    exitCode = none(int),
    error = outcome & ": " & CancelReason,
    fallback = StatusEvent(status: stCancelled, message: outcome),
  )
