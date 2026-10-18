## Defines typed simulation events and their JSON payload serialization.
##
## Also owns `RunnerSettings`, since the `SETTING` event serializes it field by
## field; defaults and helpers live in `settings`.
##
## Events are delivery-independent. Sinks may add sequence or routing metadata
## without changing the event payload.

import std/[json, math, options, times]

const EventTimestampFormat = "yyyy-MM-dd'T'HH:mm:ss"

proc formatEventTimestamp(timestamp: DateTime): string {.gcsafe.} =
  ## Formats `timestamp` in the wire format, parsed once at compile time.
  timestamp.format(EventTimestampFormat)

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
    sevNotice = "Notice"
    sevWarning = "Warning"
    sevFatal = "Fatal"

  TrnexeGuiVisibility* = enum
    ## TrnEXE window mode; minimized modes launch visible, then minimize through Win32.
    guiKeepOpen = "keepOpen" # Visible; window stays open after the run.
    guiAutoClose = "autoClose" # Visible; window closes when the run finishes.
    guiMinimized = "minimized" # Minimized; window stays open after the run.
    guiMinimizedAuto = "minimizedAuto" # Minimized; closes after the run.
    guiHidden = "hidden" # No window at all.

  RunnerSettings* = object
    ## Settings controlling TRNSYS launch detection and runtime monitoring.
    ## Field names and order are the `SETTING` event's wire keys.
    trnexePath*: string
    guiVisibility*: TrnexeGuiVisibility
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

  SettingEvent* = object ## Runner settings applied to a simulation.
    timestamp*: DateTime
    settings*: RunnerSettings

  StatusEvent* = object ## A simulation lifecycle transition with outcome details.
    timestamp*: DateTime
    status*: SimStatus
    message*: string

  ConfigEvent* = object ## Fixed parameters for a simulation run.
    timestamp*: DateTime
    start*: float
    stop*: float
    step*: float

  ProgressEvent* = object ## Current simulation progress and wall-clock timing.
    timestamp*: DateTime
    time*: float
    percent*: float
    elapsedMs*: float
    etaMs*: float

  LogEvent* = object ## A severity-tagged message parsed from the TRNSYS log.
    timestamp*: DateTime
    severity*: LogSeverity
    time*: float
    unitId*: Option[int]
    typeId*: Option[int]
    messageCode*: Option[int]
    message*: Option[string]
    information*: Option[string]

  SimulationEventKind* = enum
    ## Discriminant for a structured simulation event; values are JSON `kind` tags.
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

proc addIfSome[T](node: JsonNode, key: string, value: Option[T]) =
  ## Adds an optional field only when it has a value.
  if value.isSome:
    node[key] = %value.get()

proc `%`(event: SettingEvent): JsonNode =
  ## Serializes the applied runner settings.
  result = newJObject()
  result["kind"] = %($eventSetting)
  result["timestamp"] = %event.timestamp.formatEventTimestamp()
  for key, value in event.settings.fieldPairs:
    result[key] = %value

proc `%`(event: StatusEvent): JsonNode =
  ## Serializes a lifecycle transition.
  result = newJObject()
  result["kind"] = %($eventStatus)
  result["timestamp"] = %event.timestamp.formatEventTimestamp()
  result["status"] = %($event.status)
  result["message"] = %event.message

proc `%`(event: ConfigEvent): JsonNode =
  ## Serializes the fixed simulation parameters.
  result = newJObject()
  result["kind"] = %($eventConfig)
  result["timestamp"] = %event.timestamp.formatEventTimestamp()
  result["start"] = %event.start
  result["stop"] = %event.stop
  result["step"] = %event.step

proc `%`(event: ProgressEvent): JsonNode =
  ## Serializes simulation progress using the established wire precision.
  result = newJObject()
  result["kind"] = %($eventProgress)
  result["timestamp"] = %event.timestamp.formatEventTimestamp()
  result["time"] = %event.time.round(2)
  result["percent"] = %event.percent.round(4)
  result["elapsedMs"] = %event.elapsedMs.round(2)
  result["etaMs"] = %event.etaMs.round(2)

proc `%`(event: LogEvent): JsonNode =
  ## Serializes a log event, omitting fields that are not present.
  result = newJObject()
  result["kind"] = %($eventLog)
  result["timestamp"] = %event.timestamp.formatEventTimestamp()
  result["severity"] = %($event.severity)
  result["time"] = %event.time.round(2)
  result.addIfSome("unitId", event.unitId)
  result.addIfSome("typeId", event.typeId)
  result.addIfSome("messageCode", event.messageCode)
  result.addIfSome("message", event.message)
  result.addIfSome("information", event.information)

proc `%`(event: SimulationEvent): JsonNode =
  ## Dispatches to the serializer for the active event kind.
  case event.kind
  of eventSetting:
    %event.settingData
  of eventStatus:
    %event.statusData
  of eventConfig:
    %event.configData
  of eventProgress:
    %event.progressData
  of eventLog:
    %event.logData

proc toJson*(event: SimulationEvent): JsonNode {.inline.} =
  ## Named boundary for payload serialization; sinks add delivery metadata.
  %event
