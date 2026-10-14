## Defines the events TRNRun reports and parses them from its JSON lines.
## Fields the types do not declare, such as TRNRun timestamps, are ignored.
##
## The types mirror TRNRun's own events. `test_events` checks `SettingEvent`
## against the `SETTING` event TRNRun builds, so a TRNRun option change that
## this module misses fails the tests instead of dropping settings.

import std/[json, options]

type
  SimStatus* = enum
    stPending = "PENDING"
    stLaunching = "LAUNCHING"
    stRunning = "RUNNING"
    stDone = "DONE"
    stCancelled = "CANCELLED"
    stError = "ERROR"
    stTimeout = "TIMEOUT"
    stStalled = "STALLED"

  LogSeverity* = enum
    ## Values are part of the wire protocol.
    lsNotice = "Notice"
    lsWarning = "Warning"
    lsFatal = "Fatal"

  SettingEvent* = object
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
    status*: SimStatus
    message*: string

  ConfigEvent* = object
    start*: float
    stop*: float
    step*: float

  ProgressEvent* = object
    time*: float
    percent*: float
    elapsedMs*: float
    etaMs*: float

  LogEvent* = object
    severity*: LogSeverity
    time*: float
    unitId*: Option[int]
    typeId*: Option[int]
    messageCode*: Option[int]
    message*: Option[string]
    information*: Option[string]

  SimulationEventKind* = enum
    ## Values are JSON `kind` tags.
    ekSetting = "SETTING"
    ekStatus = "STATUS"
    ekConfig = "CONFIG"
    ekProgress = "PROGRESS"
    ekLog = "LOG"

  SimulationEvent* = object
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
  ## Parses one TRNRun event.
  ##
  ## Raises `ValueError` when `node` is not a known event or has a wrong field
  ## type, and `KeyError` when it misses a required field.
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
