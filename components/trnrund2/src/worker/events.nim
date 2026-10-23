## Defines the events TRNRun reports and parses them from its JSON lines.
##
## The types mirror TRNRun's own events. Fields they do not declare, such as
## TRNRun timestamps, are ignored. `test_events` checks `SettingEvent` against
## the `SETTING` event TRNRun builds, so a TRNRun option change that this
## module misses fails the tests instead of dropping settings.

import std/[json, options]

type
  SimStatus* = enum
    ## TRNRun lifecycle status. Values are part of the wire protocol.
    stPending = "PENDING"
    stLaunching = "LAUNCHING"
    stRunning = "RUNNING"
    stDone = "DONE"
    stCancelled = "CANCELLED"
    stError = "ERROR"
    stTimeout = "TIMEOUT"
    stStalled = "STALLED"

  LogSeverity* = enum
    ## Severity of a TRNSYS log entry. Values are part of the wire protocol.
    lsNotice = "Notice"
    lsWarning = "Warning"
    lsFatal = "Fatal"

  SettingEvent* = object
    ## TRNRun settings applied to a run, reported once before anything else.
    trnexePath*: string
    guiVisibility*: string
    waitForGui*: bool
    waitForLst*: bool
    waitForTmp*: bool
    detectTimeoutMs*: int
    extraDelayMs*: int
    watchLog*: bool
    watchTmp*: bool
    watchTimeoutMs*: int
    stallTimeoutMs*: int
    pollMs*: int
    cleanOnSuccess*: bool
    killOnTimeout*: bool
    killOnStall*: bool
    severity*: LogSeverity
    writeEvents*: bool

  StatusEvent* = object
    ## A lifecycle transition, with outcome details.
    status*: SimStatus
    message*: string

  ConfigEvent* = object
    ## Simulation start, stop and time step, in simulation hours.
    start*, stop*, step*: float

  ProgressEvent* = object
    ## Simulation progress and wall-clock timing.
    time*: float ## Simulation time reached, in hours.
    percent*: float ## Fraction done, in `[0, 1]`.
    elapsedMs*, etaMs*: float

  LogEvent* = object
    ## One entry of the TRNSYS log.
    severity*: LogSeverity
    time*: float ## Simulation time of the entry, in hours.
    unitId*, typeId*, messageCode*: Option[int]
    message*, information*: Option[string]

  SimulationEventKind* = enum
    ## Values are JSON `kind` tags.
    ekSetting = "SETTING"
    ekStatus = "STATUS"
    ekConfig = "CONFIG"
    ekProgress = "PROGRESS"
    ekLog = "LOG"

  SimulationEvent* = object
    ## One event TRNRun reports about a run.
    case kind*: SimulationEventKind
    of ekSetting:
      setting*: SettingEvent
    of ekStatus:
      status*: StatusEvent
    of ekConfig:
      config*: ConfigEvent
    of ekProgress:
      progress*: ProgressEvent
    of ekLog:
      log*: LogEvent

proc parseSimulationEvent(node: JsonNode): SimulationEvent =
  ## Parses one TRNRun event; `ValueError` or `KeyError` if `node` is not a valid one.
  if node.kind != JObject:
    raise newException(ValueError, "Event must be a JSON object")

  case node["kind"].to(SimulationEventKind)
  of ekSetting:
    SimulationEvent(kind: ekSetting, setting: node.to(SettingEvent))
  of ekStatus:
    SimulationEvent(kind: ekStatus, status: node.to(StatusEvent))
  of ekConfig:
    SimulationEvent(kind: ekConfig, config: node.to(ConfigEvent))
  of ekProgress:
    SimulationEvent(kind: ekProgress, progress: node.to(ProgressEvent))
  of ekLog:
    SimulationEvent(kind: ekLog, log: node.to(LogEvent))

proc parseEventLine*(line: string): Option[SimulationEvent] =
  ## Parses one line of TRNRun output; none if it is not a valid event.
  try:
    some(parseSimulationEvent(parseJson(line)))
  except ValueError, KeyError:
    none(SimulationEvent)
