## Holds the daemon-side state of one simulation.
##
## The daemon thread alone owns every `Simulation`. TRNRun output is folded in
## one line at a time. Log entries are only counted here; the scheduler stores
## them in the database.
##
## Timestamps are UTC ISO 8601 text with milliseconds, such as
## `2026-10-09T14:03:12.345Z`, which SQLite date functions accept and which
## sort chronologically as text.

import std/[json, options, times]
import ./events

type
  SimulationState* = enum
    ## Lifecycle of a simulation, independent of TRNRun `STATUS`.
    ##
    ## `QUEUED → ACCEPTED → RUNNING → FINISHED`. A simulation whose TRNRun
    ## fails to launch goes from `ACCEPTED` to `FINISHED`; one the daemon stops
    ## tracking first, at shutdown or when it exits, is finished as interrupted
    ## from whatever state it reached.
    ssQueued = "QUEUED" ## Submitted, waiting for an idle worker.
    ssAccepted = "ACCEPTED" ## A pool slot is reserved; worker pickup may be pending.
    ssRunning = "RUNNING" ## The TRNRun process started.
    ssFinished = "FINISHED" ## Completed or failed; see `status`.

  Simulation* = object
    ## Everything the daemon knows about one submitted simulation.
    # Submission
    runId*: string
    deckFile*: string ## Absolute, validated at submission.
    trnrunArgs*: seq[string]
    # Daemon bookkeeping
    state*: SimulationState
    submittedAt*: string ## When the daemon accepted the submission.
    startedAt*: Option[string] ## When the TRNRun process started; none if it never did.
    finishedAt*: Option[string] ## When the simulation finished.
    # TRNRun results
    exitCode*: Option[int]
      ## TRNRun exit code; none until it exits, or if it never launched.
    error*: string
      ## Execution error reported by the daemon, independent of TRNRun status.
    setting*: Option[SettingEvent]
    status*: Option[StatusEvent]
    config*: Option[ConfigEvent]
    progress*: Option[ProgressEvent]
    notices*: int
    warnings*: int
    fatals*: int

const TerminalStatuses =
  {statusDone, statusCancelled, statusError, statusTimeout, statusStalled}
  ## TRNRun statuses that end a run.

proc timestampNow*(): string =
  ## The current time in the format of every simulation timestamp.
  now().utc().format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

# Lifecycle

proc initSimulation*(
    runId, deckFile: string, trnrunArgs: seq[string], submittedAt = timestampNow()
): Simulation =
  ## Returns a queued simulation, submitted at `submittedAt`.
  result = Simulation(
    runId: runId,
    deckFile: deckFile,
    trnrunArgs: trnrunArgs,
    state: ssQueued,
    submittedAt: submittedAt,
  )

proc start*(self: var Simulation) =
  ## Marks the simulation running once its TRNRun process started.
  self.state = ssRunning
  self.startedAt = some(timestampNow())

proc applyLine*(self: var Simulation, line: string): Option[SimulationEvent] {.discardable.} =
  ## Folds one TRNRun output line into the simulation and returns its event.
  ##
  ## `SETTING`, `STATUS`, `CONFIG` and `PROGRESS` replace the previous value;
  ## each `LOG` is counted by severity. Lines that are not valid events are
  ## ignored without changing anything, and return none.
  let event =
    try:
      parseSimulationEvent(parseJson(line))
    except ValueError, KeyError:
      return none(SimulationEvent)

  result = some(event)
  case event.kind
  of eventSetting:
    self.setting = some(event.settingData)
  of eventStatus:
    self.status = some(event.statusData)
  of eventConfig:
    self.config = some(event.configData)
  of eventProgress:
    self.progress = some(event.progressData)
  of eventLog:
    case event.logData.severity
    of Notice: inc self.notices
    of Warning: inc self.warnings
    of Fatal: inc self.fatals

proc hasTerminalStatus(self: Simulation): bool =
  ## Whether TRNRun already reported a status in `TerminalStatuses`.
  self.status.isSome and self.status.get().status in TerminalStatuses

proc finish*(self: var Simulation, exitCode: Option[int], error: string) =
  ## Marks the simulation finished once TRNRun exited or failed to launch.
  ##
  ## Guarantees a terminal status: when TRNRun did not report one, a
  ## daemon-owned `ERROR` status explains why. Execution errors are retained
  ## independently, even when TRNRun already reported a terminal status.
  self.state = ssFinished
  self.finishedAt = some(timestampNow())
  self.exitCode = exitCode
  self.error = error
  if self.hasTerminalStatus():
    return

  let message = if error.len > 0: error else: "TRNRun exited without a terminal status"
  self.status = some(StatusEvent(status: statusError, message: message))

proc interrupt*(self: var Simulation, reason: string) =
  ## Finishes a simulation the daemon stops tracking before TRNRun exits.
  ##
  ## A queued simulation never started; any other may have, and its TRNRun is
  ## killed with the daemon. Either way it is CANCELLED, unless TRNRun already
  ## reported a terminal status, and its error gives `reason`, such as
  ## `Not started: the daemon shut down`.
  let outcome = if self.state == ssQueued: "Not started" else: "Interrupted"
  if not self.hasTerminalStatus():
    self.status = some(StatusEvent(status: statusCancelled, message: outcome))
  self.finish(none(int), outcome & ": " & reason)

proc succeeded*(self: Simulation): bool =
  ## Success requires both a successful TRNRun outcome and no execution error.
  self.state == ssFinished and
    self.status.isSome and self.status.get().status == statusDone and
    self.exitCode == some(0) and self.error.len == 0
