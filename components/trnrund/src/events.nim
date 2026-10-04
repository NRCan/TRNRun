## Defines the events TRNRun reports and parses them from its JSON lines.
## Fields the types do not declare, such as TRNRun timestamps, are ignored.

import std/[json, options]

type
  SimStatus* = enum
    ## Lifecycle states reported for a simulation.
    statusPending = "PENDING"
    statusLaunching = "LAUNCHING"
    statusRunning = "RUNNING"
    statusDone = "DONE"
    statusCancelled = "CANCELLED"
    statusError = "ERROR"
    statusTimeout = "TIMEOUT"
    statusStalled = "STALLED"

  LogSeverity* = enum
    ## Severity of a TRNSYS log entry. Values are part of the wire protocol.
    Notice = "Notice"
    Warning = "Warning"
    Fatal = "Fatal"

  SettingEvent* = object ## TRNRun settings applied to a simulation.
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

  StatusEvent* = object ## A simulation lifecycle transition with outcome details.
    status*: SimStatus
    message*: string

  ConfigEvent* = object ## Fixed parameters for a simulation run.
    start*: float
    stop*: float
    step*: float

  ProgressEvent* = object ## Current simulation progress and wall-clock timing.
    time*: float
    percent*: float
    elapsedMs*: float
    etaMs*: float

  LogEvent* = object ## A severity-tagged message parsed from the TRNSYS log.
    severity*: LogSeverity
    time*: float
    unitId*: Option[int]
    typeId*: Option[int]
    messageCode*: Option[int]
    message*: Option[string]
    information*: Option[string]

  SimulationEventKind* = enum
    ## Discriminant for a structured simulation event. Values are JSON `kind`
    ## tags.
    eventSetting = "SETTING"
    eventStatus = "STATUS"
    eventConfig = "CONFIG"
    eventProgress = "PROGRESS"
    eventLog = "LOG"

  SimulationEvent* = object ## A closed union of events produced during one simulation.
    case kind*: SimulationEventKind
    of eventSetting:
      settingData*: SettingEvent
    of eventStatus:
      statusData*: StatusEvent
    of eventConfig:
      configData*: ConfigEvent
    of eventProgress:
      progressData*: ProgressEvent
    of eventLog:
      logData*: LogEvent

proc parseSimulationEvent*(node: JsonNode): SimulationEvent =
  ## Parses one TRNRun event line. Raises `ValueError` when `node` is not a
  ## known event or has a wrong field type, and `KeyError` when it misses a
  ## required field.
  if node.kind != JObject:
    raise newException(ValueError, "Event must be a JSON object")

  case node["kind"].to(SimulationEventKind)
  of eventSetting:
    SimulationEvent(kind: eventSetting, settingData: node.to(SettingEvent))
  of eventStatus:
    SimulationEvent(kind: eventStatus, statusData: node.to(StatusEvent))
  of eventConfig:
    SimulationEvent(kind: eventConfig, configData: node.to(ConfigEvent))
  of eventProgress:
    SimulationEvent(kind: eventProgress, progressData: node.to(ProgressEvent))
  of eventLog:
    SimulationEvent(kind: eventLog, logData: node.to(LogEvent))
