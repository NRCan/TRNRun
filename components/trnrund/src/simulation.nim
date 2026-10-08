## Holds the daemon-side state of one simulation.
##
## The daemon thread alone owns every `Simulation`. TRNRun output is folded in
## one line at a time. The scheduler stamps each change with its revision, and
## each log entry keeps the revision it arrived in, so a client can ask for
## what changed since a revision it holds.

import std/[algorithm, json, options]
import ./events

type
  SimulationState* = enum
    ## Lifecycle of a simulation, independent of TRNRun `STATUS`.
    ##
    ## `QUEUED → ACCEPTED → RUNNING → FINISHED`. A simulation whose TRNRun
    ## fails to launch goes from `ACCEPTED` to `FINISHED`; one still queued at
    ## shutdown goes from `QUEUED` to `FINISHED`, cancelled.
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
    revision*: int ## Scheduler revision of the latest change.
    logRevisions: seq[int] ## Revision each entry of `logs` arrived in, never serialized.
    # TRNRun results
    exitCode*: Option[int]
      ## TRNRun exit code; none until it exits, or if it never launched.
    error*: string
      ## Execution error reported by the daemon, independent of TRNRun status.
    setting*: Option[SettingEvent]
    status*: Option[StatusEvent]
    config*: Option[ConfigEvent]
    progress*: Option[ProgressEvent]
    logs*: seq[LogEvent]
    notices*: int
    warnings*: int
    fatals*: int

const TerminalStatuses =
  {statusDone, statusCancelled, statusError, statusTimeout, statusStalled}
  ## TRNRun statuses that end a run.

# Lifecycle

proc initSimulation*(runId, deckFile: string, trnrunArgs: seq[string]): Simulation =
  ## Returns a queued simulation.
  result = Simulation(
    runId: runId, deckFile: deckFile, trnrunArgs: trnrunArgs, state: ssQueued
  )

proc applyLine*(self: var Simulation, line: string, revision: int) =
  ## Folds one TRNRun output line into the simulation as of `revision`.
  ##
  ## `SETTING`, `STATUS`, `CONFIG` and `PROGRESS` replace the previous value;
  ## each `LOG` is appended and counted by severity. Lines that are not valid
  ## events are ignored without changing state, revision included.
  let event =
    try:
      parseSimulationEvent(parseJson(line))
    except ValueError, KeyError:
      return

  self.revision = revision
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
    self.logs.add(event.logData)
    self.logRevisions.add(revision)
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
  self.exitCode = exitCode
  self.error = error
  if self.hasTerminalStatus():
    return

  let message = if error.len > 0: error else: "TRNRun exited without a terminal status"
  self.status = some(StatusEvent(status: statusError, message: message))

proc succeeded*(self: Simulation): bool =
  ## Success requires both a successful TRNRun outcome and no execution error.
  self.state == ssFinished and
    self.status.isSome and self.status.get().status == statusDone and
    self.exitCode == some(0) and self.error.len == 0

proc logStartAfter*(self: Simulation, revision: int): int =
  ## Index of the first log entry that arrived after `revision`.
  self.logRevisions.lowerBound(revision + 1)

proc `%`*(self: Simulation): JsonNode =
  ## Serializes every field but the ever-growing `logs`, plus `succeeded`.
  result = newJObject()
  for name, value in self.fieldPairs:
    when name notin ["logs", "logRevisions"]:
      result[name] = %value
  result["succeeded"] = %self.succeeded()

proc toJson*(self: Simulation, logStart: int): JsonNode =
  ## Serializes the simulation with its log entries from `logStart` on.
  ##
  ## `logStart`, clamped to the entries held, is reported back, so a client
  ## can tell where the entries it receives belong.
  let start = min(logStart, self.logs.len)
  result = %self
  result["logStart"] = %start
  result["logs"] = %self.logs[start ..< self.logs.len]
