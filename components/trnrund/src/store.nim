## Keeps every run and its logs in memory, the only record of their state.
##
## The store numbers runs itself: `runId` starts at 1 and only grows, so it is
## not reused while the daemon runs. Each run keeps its own logs, oldest first,
## so releasing a finished run frees its logs with it.
## Timestamps are UTC ISO 8601 text with milliseconds, such as
## `2026-10-09T14:03:12.345Z`, which sort chronologically as text.
##
## `addJson` writes a run, with all its logs, as the protocol object clients
## read, straight into a reply string.

import std/[json, options, tables, times]
import ./[events, validate]

type
  SimulationState* = enum
    ## Run lifecycle, separate from `STATUS`; failed launches and queued cancels skip `RUNNING`.
    ssQueued = "QUEUED" ## Submitted, waiting for a free slot.
    ssRunning = "RUNNING" ## The TRNRun process started.
    ssFinished = "FINISHED" ## Completed or failed; see `succeeded`.

  Run* = object
    ## One run; a value TRNRun has not reported yet is none.
    runId*: int
    label*: Option[string]
    state*: SimulationState
    trnrunStatus*: Option[SimStatus]
    trnrunMessage*: Option[string]
    percent*, simTime*, elapsedMs*, etaMs*: Option[float]
    notices*, warnings*, fatals*: int ## Every log entry, kept or not.
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

  Store* = object
    ## Every run not released yet.
    runs: Table[int, Run] ## By runId.
    lastRunId: int

const TerminalStatuses = {stDone, stCancelled, stError, stTimeout, stStalled}
  ## TRNRun statuses that end a run.

proc timestamp(): string =
  ## The current time, as every timestamp is kept.
  now().utc().format("yyyy-MM-dd'T'HH:mm:ss'.'fff'Z'")

# Runs

proc initStore*(): Store =
  ## An empty store.
  Store()

proc contains*(store: Store, runId: int): bool =
  ## Whether `runId` was added and not released.
  runId in store.runs

proc `[]`*(store: Store, runId: int): lent Run =
  ## The run `runId`; `KeyError` unless `runId in store`.
  store.runs[runId]

proc submit*(
    store: var Store, deckFile: string, trnrunArgs: seq[string] = @[], label = none(string)
): int =
  ## Adds a new run as `QUEUED` and returns its new `runId`.
  inc store.lastRunId
  result = store.lastRunId
  store.runs[result] = Run(runId: result, label: label, state: ssQueued,
    submittedAt: timestamp(), deckFile: deckFile, trnrunArgs: trnrunArgs)

proc start*(store: var Store, runId: int) =
  ## Marks `runId` running once its TRNRun process has started.
  store.runs[runId].state = ssRunning
  store.runs[runId].startedAt = some(timestamp())

proc record*(store: var Store, runId: int, event: SimulationEvent) =
  ## Saves one TRNRun event of `runId`: a `LOG` is counted and appended,
  ## any other replaces the previous value.
  template run: untyped = store.runs[runId]
  case event.kind
  of ekSetting:
    run.setting = some(event.setting)
  of ekStatus:
    run.trnrunStatus = some(event.status.status)
    run.trnrunMessage = some(event.status.message)
  of ekConfig:
    run.startTime = some(event.config.start)
    run.stopTime = some(event.config.stop)
    run.timeStep = some(event.config.step)
  of ekProgress:
    run.percent = some(event.progress.percent)
    run.simTime = some(event.progress.time)
    run.elapsedMs = some(event.progress.elapsedMs)
    run.etaMs = some(event.progress.etaMs)
  of ekLog:
    case event.log.severity
    of lsNotice: inc run.notices
    of lsWarning: inc run.warnings
    of lsFatal: inc run.fatals
    run.logs.add(event.log)

proc finish(
    store: var Store, runId: int, exitCode: Option[int], error: string, fallback: StatusEvent
) =
  ## Marks `runId` finished, with `fallback` as its status unless TRNRun reported a terminal one.
  template run: untyped = store.runs[runId]
  if run.trnrunStatus.isNone or run.trnrunStatus.get() notin TerminalStatuses:
    run.trnrunStatus = some(fallback.status)
    run.trnrunMessage = some(fallback.message)
  # It succeeded only with a `DONE` status from TRNRun, exit code 0, and no execution error.
  run.succeeded = some(run.trnrunStatus == some(stDone) and exitCode == some(0) and error.len == 0)
  run.state = ssFinished
  run.finishedAt = some(timestamp())
  run.exitCode = exitCode
  run.error = if error.len > 0: some(error) else: none(string)

proc finish*(store: var Store, runId: int, exitCode: Option[int], error: string) =
  ## Marks `runId` finished once TRNRun exited or failed to launch; `ERROR` if it reported no end.
  let message = if error.len > 0: error else: "TRNRun exited without a terminal status"
  store.finish(runId, exitCode, error, StatusEvent(status: stError, message: message))

proc cancel*(store: var Store, runId: int, started: bool, reason: string) =
  ## Finishes `runId` as CANCELLED, with `reason` after `Interrupted: ` or `Not started: `.
  let outcome = if started: "Interrupted" else: "Not started"
  store.finish(runId, none(int), outcome & ": " & reason,
    StatusEvent(status: stCancelled, message: outcome))

proc release*(store: var Store, runId: int) =
  ## Deletes the run `runId` with its logs, doing nothing if it is unknown;
  ## `InputError` if it is not `FINISHED`.
  if runId in store.runs and store.runs[runId].state != ssFinished:
    raise newException(InputError, "Run " & $runId & " is not FINISHED")
  store.runs.del(runId)

# JSON

proc `%`(log: LogEvent): JsonNode =
  ## `log` as a protocol log object.
  %*{"severity": log.severity, "simTime": log.time, "unitId": log.unitId,
    "typeId": log.typeId, "messageCode": log.messageCode, "message": log.message,
    "information": log.information}

proc addJson*(s: var string, run: Run) =
  ## Appends `run` as a protocol run object, with all its logs.
  let node = newJObject()
  for name, value in run.fieldPairs:
    node[name] = %value
  s.toUgly(node)
