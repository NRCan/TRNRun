## events.nim - typed simulation events and JSON serialization.
##
## Defines the events produced during a TRNSYS simulation independently of
## their delivery destination. The standalone runner serializes these values
## as one JSON object per line; the daemon can later wrap the same events with
## run-specific routing metadata.

import std/[json, math, options, times]

const EventTimestampFormat* = "yyyy-MM-dd'T'HH:mm:ss"

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

  StatusEvent* = object
    ## A simulation lifecycle transition.
    timestamp*: DateTime
    status*: SimStatus

  ConfigEvent* = object
    ## Fixed parameters for a simulation run.
    timestamp*: DateTime
    start*: float
    stop*: float
    step*: float

  ProgressEvent* = object
    ## Current simulation progress and wall-clock timing.
    timestamp*: DateTime
    time*: float
    percent*: float
    elapsedMs*: float
    etaMs*: float

  LogEvent* = object
    ## A severity-tagged message parsed from the TRNSYS log.
    timestamp*: DateTime
    severity*: LogSeverity
    time*: float
    unitId*: Option[int]
    typeId*: Option[int]
    messageCode*: Option[int]
    message*: Option[string]
    information*: Option[string]

  SimulationEventKind* = enum
    ## Discriminant for a structured simulation event. Values are JSON `kind` tags.
    eventStatus = "STATUS"
    eventConfig = "CONFIG"
    eventProgress = "PROGRESS"
    eventLog = "LOG"

  SimulationEvent* = object
    ## A closed union of events produced during one simulation.
    case kind*: SimulationEventKind
    of eventStatus:
      statusData*: StatusEvent
    of eventConfig:
      configData*: ConfigEvent
    of eventProgress:
      progressData*: ProgressEvent
    of eventLog:
      logData*: LogEvent

proc statusEvent*(
    status: SimStatus, timestamp: DateTime = now()
): SimulationEvent =
  ## Creates a lifecycle status event.
  result = SimulationEvent(
    kind: eventStatus,
    statusData: StatusEvent(timestamp: timestamp, status: status),
  )

proc configEvent*(
    start, stop, step: float, timestamp: DateTime = now()
): SimulationEvent =
  ## Creates an event describing fixed simulation parameters.
  result = SimulationEvent(
    kind: eventConfig,
    configData: ConfigEvent(
      timestamp: timestamp,
      start: start,
      stop: stop,
      step: step,
    ),
  )

proc progressEvent*(
    time, percent, elapsedMs, etaMs: float,
    timestamp: DateTime = now(),
): SimulationEvent =
  ## Creates a simulation progress event.
  result = SimulationEvent(
    kind: eventProgress,
    progressData: ProgressEvent(
      timestamp: timestamp,
      time: time,
      percent: percent,
      elapsedMs: elapsedMs,
      etaMs: etaMs,
    ),
  )

proc logEvent*(
    severity: LogSeverity,
    time: float,
    unitId: Option[int] = none(int),
    typeId: Option[int] = none(int),
    messageCode: Option[int] = none(int),
    message: Option[string] = none(string),
    information: Option[string] = none(string),
    timestamp: DateTime = now(),
): SimulationEvent =
  ## Creates a structured TRNSYS log event.
  result = SimulationEvent(
    kind: eventLog,
    logData: LogEvent(
      timestamp: timestamp,
      severity: severity,
      time: time,
      unitId: unitId,
      typeId: typeId,
      messageCode: messageCode,
      message: message,
      information: information,
    ),
  )

proc `%`*(event: StatusEvent): JsonNode =
  ## Serializes a lifecycle status event.
  result = newJObject()
  result["kind"] = %($eventStatus)
  result["timestamp"] = %event.timestamp.format(EventTimestampFormat)
  result["status"] = %($event.status)

proc `%`*(event: ConfigEvent): JsonNode =
  ## Serializes fixed simulation parameters.
  result = newJObject()
  result["kind"] = %($eventConfig)
  result["timestamp"] = %event.timestamp.format(EventTimestampFormat)
  result["start"] = %event.start
  result["stop"] = %event.stop
  result["step"] = %event.step

proc `%`*(event: ProgressEvent): JsonNode =
  ## Serializes simulation progress using the established wire precision.
  result = newJObject()
  result["kind"] = %($eventProgress)
  result["timestamp"] = %event.timestamp.format(EventTimestampFormat)
  result["time"] = %event.time.round(2)
  result["percent"] = %event.percent.round(4)
  result["elapsed"] = %event.elapsedMs.round(2)
  result["eta"] = %event.etaMs.round(2)

proc `%`*(event: LogEvent): JsonNode =
  ## Serializes a log event, omitting fields that are not present.
  result = newJObject()
  result["kind"] = %($eventLog)
  result["timestamp"] = %event.timestamp.format(EventTimestampFormat)
  result["severity"] = %($event.severity)
  result["time"] = %event.time
  if event.unitId.isSome:
    result["unitID"] = %event.unitId.get()
  if event.typeId.isSome:
    result["typeID"] = %event.typeId.get()
  if event.messageCode.isSome:
    result["messageCode"] = %event.messageCode.get()
  if event.message.isSome:
    result["message"] = %event.message.get()
  if event.information.isSome:
    result["information"] = %event.information.get()

proc `%`*(event: SimulationEvent): JsonNode =
  ## Dispatches a union event to its payload-specific serializer.
  case event.kind
  of eventStatus:
    %event.statusData
  of eventConfig:
    %event.configData
  of eventProgress:
    %event.progressData
  of eventLog:
    %event.logData

proc toJson*(event: SimulationEvent): JsonNode {.inline.} =
  ## Readable alias for the standard `std/json` serialization operator.
  ##
  ## This is the event's payload only. Sinks add the delivery metadata that
  ## completes a wire line; see `sequencedEventSink` in `eventsink`.
  %event
