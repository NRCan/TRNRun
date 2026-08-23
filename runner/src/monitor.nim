## Monitors a running TRNSYS process by polling Type3830 `.tmp` and TRNSYS
## `.log` output and emitting `CONFIG`, `PROGRESS`, and `LOG` events.
##
## Event shapes:
##
## ```
## {"kind":"CONFIG",   "timestamp":…, "start":…, "stop":…, "step":…}
## {"kind":"PROGRESS", "timestamp":…, "time":…, "percent":…, "elapsed":…, "eta":…}
## {"kind":"LOG",      "timestamp":…, "severity":…, "time":…, …}
## ```
##
## `elapsed` and `eta` are milliseconds; `percent` is in `[0, 1]`.
## `monitor` blocks until process exit, a fatal log entry, timeout, or stall,
## and returns the corresponding `SimResult`.

import std/[monotimes, options, os, osproc, strutils, times]
import ./events
import ./eventsink
import ./processwait
import ./status

# Types
type
  SimLog = object
    ## A single parsed TRNSYS log entry.
    timestamp: DateTime # Wall-clock time the entry was parsed.
    severity: LogSeverity # Severity of the message.
    time: float # Simulation time in hours.
    unitId: Option[int] # TRNSYS unit ID when applicable.
    typeId: Option[int] # TRNSYS type ID when applicable.
    messageCode: Option[int] # TRNSYS message code when applicable.
    message: Option[string] # TRNSYS message text when present.
    information: Option[string] # TRNSYS additional information when present.

  SimConfig = object
    ## Fixed TRNSYS simulation parameters; constant for the entire run.
    timestamp: DateTime # Wall-clock time the config was first read.
    start: float # Simulation start time in hours.
    stop: float # Simulation stop time in hours.
    step: float # Simulation time step in hours.

  SimProgress = object
    ## Current simulation time sampled from a Type3830 tmp file.
    timestamp: DateTime # Wall-clock time the file was read; wire payload only.
    mono: MonoTime # Same instant on the monotonic clock; used for durations.
    time: float # Current simulation time in hours.

  TmpSnapshot = object
    ## A fully-parsed read of a Type3830 tmp file.
    config: SimConfig
    progress: SimProgress

  MonitorState = object
    ## Mutable book-keeping shared across polling ticks.
    tmpFile: string
    logFile: string
    processStartTime: MonoTime
    monitorStartTime: MonoTime
    watchLog: bool
    watchTmp: bool
    severity: LogSeverity
    logOffset: int64
    lastSnapshot: Option[TmpSnapshot]
    eventSink: EventSink
    watchTimeoutMs: int
    stallTimeoutMs: int
    lastProgressChange: MonoTime

# Progress and TMP data
proc percent(self: SimProgress, config: SimConfig): float =
  ## Returns simulation progress in [0, 1] relative to `config`.
  if config.stop <= config.start: return 0.0
  clamp((self.time - config.start) / (config.stop - config.start), 0.0, 1.0)

proc elapsed(self: SimProgress, realStart: MonoTime): float =
  ## Returns milliseconds elapsed since `realStart`.
  ##
  ## Monotonic on purpose: a wall-clock difference can jump or go negative when
  ## the system clock is stepped by NTP or a DST change, and this value both
  ## ships on the wire and divides into `eta`.
  (self.mono - realStart).inMilliseconds.float

proc eta(self: SimProgress, config: SimConfig, realStart: MonoTime): float =
  ## Returns estimated milliseconds remaining, or 0 if progress is negligible.
  let percentage = self.percent(config)
  if percentage < 0.001: return 0.0
  let elapsedMs = self.elapsed(realStart)
  max(0.0, elapsedMs / percentage - elapsedMs)

# Event conversion
proc configEvent(config: SimConfig): SimulationEvent =
  SimulationEvent(
    kind: eventConfig,
    configData: ConfigEvent(
      timestamp: config.timestamp,
      start: config.start,
      stop: config.stop,
      step: config.step,
    ),
  )

proc progressEvent(
    progress: SimProgress,
    config: SimConfig,
    realStart: MonoTime,
): SimulationEvent =
  SimulationEvent(
    kind: eventProgress,
    progressData: ProgressEvent(
      timestamp: progress.timestamp,
      time: progress.time,
      percent: progress.percent(config),
      elapsedMs: progress.elapsed(realStart),
      etaMs: progress.eta(config, realStart),
    ),
  )

proc logEvent(entry: SimLog): SimulationEvent =
  SimulationEvent(
    kind: eventLog,
    logData: LogEvent(
      timestamp: entry.timestamp,
      severity: entry.severity,
      time: entry.time,
      unitId: entry.unitId,
      typeId: entry.typeId,
      messageCode: entry.messageCode,
      message: entry.message,
      information: entry.information,
    ),
  )

# Log parsing
const LogIgnoredValues = [
  "Not applicable",
  "Not available",
  "Not applicable or not available",
]

# Utilities
proc splitKeyValue(line: string): tuple[key, val: string] =
  ## Splits `line` at the first `:` into a key and value, both stripped.
  result = ("", "")
  let i = line.find(':')
  if i >= 0:
    result = (line[0 ..< i].strip(), line[i + 1 .. ^1].strip())

proc splitValue(line: string): string =
  splitKeyValue(line).val

# Field parsers
proc parseHeader(line: string, log: var SimLog) =
  ## Parses `*** <severity> at time : <time>`.
  let (key, val) = splitKeyValue(line)

  log.severity =
    if "Warning" in key: Warning
    elif "Fatal" in key: Fatal
    else: Notice

  log.time = parseFloat(val)

proc parseUnitId(line: string, log: var SimLog) =
  ## Parses `Generated by Unit : <unitID>`.
  let val = splitValue(line)
  if val notin LogIgnoredValues:
    log.unitId = some(parseInt(val))

proc parseTypeId(line: string, log: var SimLog) =
  ## Parses `Generated by Type : <typeID>`.
  let val = splitValue(line)
  if val notin LogIgnoredValues:
    log.typeId = some(parseInt(val))

proc parseMessageCode(line: string, log: var SimLog) =
  ## Parses `TRNSYS Message <code> : <message>`.
  let (key, val) = splitKeyValue(line)

  let tokens = key.splitWhitespace()
  if tokens.len > 0:
    log.messageCode = some(parseInt(tokens[^1]))

  if val notin LogIgnoredValues:
    log.message = some(val)

proc parseMessage(line: string, log: var SimLog) =
  ## Parses `Message : <message>`.
  let val = splitValue(line)
  if val notin LogIgnoredValues:
    log.message = some(val)

proc parseInformation(line: string, log: var SimLog) =
  ## Parses `Reported information : <information>`.
  let val = splitValue(line)
  if val notin LogIgnoredValues:
    log.information = some(val)

# Dispatch table
type LogFieldParser = proc(line: string, log: var SimLog) {.noSideEffect, gcsafe.}

const LogFieldParsers: array[7, tuple[prefix: string, parser: LogFieldParser]] = [
  ("***", parseHeader),
  ("generated by unit", parseUnitId),
  ("generated by type", parseTypeId),
  ("trnsys message", parseMessageCode),
  ("reported information", parseInformation),
  ("information", parseInformation),
  ("message", parseMessage),
]

# Helpers
iterator logBlocks(lines: openArray[string]): seq[string] =
  ## Yields groups of log lines, each starting with a `***` header line.
  var current: seq[string] = @[]

  for line in lines:
    if line.startsWith("***"):
      if current.len > 0:
        yield current
      current = @[line]
    elif current.len > 0:
      current.add(line)

  if current.len > 0:
    yield current

proc parseLogBlock(blockLines: openArray[string]): Option[SimLog] =
  ## Parses a single TRNSYS log block into a `SimLog`.
  if blockLines.len == 0 or not blockLines[0].startsWith("***"):
    return none(SimLog)

  var entry = SimLog(timestamp: now())

  for line in blockLines:
    let stripped = line.strip()
    let lower = stripped.toLowerAscii()
    for (prefix, parser) in LogFieldParsers:
      if lower.startsWith(prefix):
        try:
          parser(stripped, entry)
        except ValueError:
          discard
        break

  result = some(entry)

proc readNewLines(offset: var int64, path: string): seq[string] =
  ## Reads newly appended *complete* lines from `path`, advancing `offset` and
  ## resetting it if the file was truncated. A trailing partial line is left
  ## unconsumed so a record the writer has not finished is never torn in two.
  result = @[]
  var file = default(File)
  if not open(file, path, fmRead):
    return
  defer: file.close()

  let size = file.getFileSize()
  if offset > size:
    stderr.writeLine("[Monitor] Log file truncated (", path, "); re-reading from start.")
    offset = 0
  if offset >= size:
    return

  file.setFilePos(offset)
  var chunk = newString(int(size - offset))
  chunk.setLen(file.readBuffer(addr chunk[0], chunk.len))

  let lastNewline = chunk.rfind('\n')
  if lastNewline < 0:
    return

  offset += int64(lastNewline + 1)
  result = chunk[0 .. lastNewline].splitLines()
  result.setLen(result.len - 1)


# Iterator
iterator readLog(offset: var int64, path: string): SimLog =
  ## Yields log entries appended since the last call with the same `offset`.
  for blockLines in logBlocks(readNewLines(offset, path)):
    let parsed = parseLogBlock(blockLines)
    if parsed.isSome:
      yield parsed.get()

# TMP parsing
proc parseTmpContent(content: string): Option[TmpSnapshot] =
  ## Parses raw Type3830 tmp content of the form
  ## `currentTime, start, stop, step`.
  let
    stripped = content.strip()
    parts = stripped.split(',')

  if parts.len != 4:
    stderr.writeLine("[Monitor] Malformed tmp content (expected 4 fields, got ", parts.len, "): ", stripped)
    return none(TmpSnapshot)

  try:
    let
      timestamp = now()
      monoTime = getMonoTime()

    return some TmpSnapshot(
      progress: SimProgress(
        timestamp: timestamp,
        mono: monoTime,
        time: parseFloat(parts[0].strip()),
      ),
      config: SimConfig(
        timestamp: timestamp,
        start: parseFloat(parts[1].strip()),
        stop: parseFloat(parts[2].strip()),
        step: parseFloat(parts[3].strip()),
      ),
    )
  except ValueError as error:
    stderr.writeLine("[Monitor] Failed to parse tmp fields: ", error.msg, " | content: ", stripped)
    return none(TmpSnapshot)

proc readTmp(path: string): Option[TmpSnapshot] =
  ## Reads and parses a Type3830 tmp file; returns `none` on any I/O or parse
  ## error.
  try:
    return parseTmpContent(readFile(path))
  except CatchableError:
    return none(TmpSnapshot)

# Polling
proc pollTmp(state: var MonitorState) =
  ## Reads the tmp file and emits config/progress events as needed, skipping
  ## silently on I/O or parse errors.
  let snapshot = readTmp(state.tmpFile)
  if snapshot.isNone:
    return

  let current = snapshot.get()

  let
    isFirstSnapshot = state.lastSnapshot.isNone
    previousTime =
      if isFirstSnapshot:
        current.progress.time
      else:
        state.lastSnapshot.get().progress.time
    progressChanged = isFirstSnapshot or current.progress.time != previousTime
    progressAdvanced = isFirstSnapshot or current.progress.time > previousTime

  if isFirstSnapshot:
    state.eventSink(configEvent(current.config))
  if progressChanged:
    state.eventSink(progressEvent(current.progress, current.config, state.processStartTime))
  if progressAdvanced:
    state.lastProgressChange = current.progress.mono

  state.lastSnapshot = some(current)

proc pollLog(state: var MonitorState, emitLogs: bool = true): bool =
  ## Drains new log entries and returns `true` on a Fatal entry. When
  ## `emitLogs` is true, entries at or above the threshold are also emitted.
  for entry in readLog(state.logOffset, state.logFile):
    if emitLogs and entry.severity >= state.severity:
      state.eventSink(logEvent(entry))

    if entry.severity == Fatal:
      return true

  return false

proc tick(state: var MonitorState): bool =
  ## Polls TMP before log output and returns `true` if the log contains Fatal.
  if state.watchTmp:
    state.pollTmp()
  if state.watchLog:
    return state.pollLog()
  return false

proc isTimedOut(state: MonitorState, currentTime: MonoTime): bool =
  ## Returns `true` if the overall monitoring duration has exceeded
  ## `watchTimeoutMs`.
  state.watchTimeoutMs > 0 and (currentTime - state.monitorStartTime).inMilliseconds >= state.watchTimeoutMs

proc isStalled(state: MonitorState, currentTime: MonoTime): bool =
  ## Returns `true` if simulation time has not advanced for `stallTimeoutMs`
  ## while under 100 % (requires `watchTmp`).
  if not state.watchTmp or state.stallTimeoutMs <= 0 or state.lastSnapshot.isNone:
    return false

  let snapshot = state.lastSnapshot.get()
  if snapshot.progress.percent(snapshot.config) >= 1.0:
    return false

  return (currentTime - state.lastProgressChange).inMilliseconds >= state.stallTimeoutMs

proc clampTimeout(timeoutMs, pollMs: int, name: string): int =
  ## Raises `timeoutMs` to `pollMs` when smaller, since finer thresholds would
  ## trigger prematurely; 0 stays disabled.
  if timeoutMs > 0 and timeoutMs < pollMs:
    stderr.writeLine("[Monitor] ", name, " (", timeoutMs, " ms) is less than pollMs (", pollMs, " ms); using ", pollMs, " ms instead.")
    return pollMs
  return timeoutMs

# Public API
proc monitor*(
    process: Process,
    deckFile: string,
    startTime: MonoTime,
    eventSink: EventSink,
    watchLog: bool = true,
    watchTmp: bool = true,
    pollMs: int = 100,
    severity: LogSeverity = Notice,
    watchTimeoutMs: int = 0,
    stallTimeoutMs: int = 0,
): SimResult =
  ## Polls the deck's `.tmp` and `.log` files until the process exits or a
  ## fatal entry, timeout, or stall is detected.
  ##
  ## Available output is drained once more after process exit. `pollMs` is
  ## clamped to at least 1 ms, and positive timeout thresholds shorter than
  ## the polling interval are raised to that interval. Stall and cancellation
  ## determination require a successful TMP snapshot.
  ##
  ## Returns `simDone` on completion, `simCancelled` when a TMP snapshot shows
  ## that the process exited before reaching 100 percent, `simFatal` on a fatal
  ## log entry, `simTimeout` on the watch timeout, or `simStalled` when progress
  ## stops.
  let
    interval = max(1, pollMs)
    monitorStartTime = getMonoTime()

  var state = MonitorState(
    tmpFile: deckFile.changeFileExt("tmp"),
    logFile: deckFile.changeFileExt("log"),
    processStartTime: startTime,
    monitorStartTime: monitorStartTime,
    watchLog: watchLog,
    watchTmp: watchTmp,
    severity: severity,
    eventSink: eventSink,
    watchTimeoutMs: clampTimeout(watchTimeoutMs, interval, "watchTimeoutMs"),
    stallTimeoutMs: clampTimeout(stallTimeoutMs, interval, "stallTimeoutMs"),
    lastProgressChange: monitorStartTime,
  )

  if not watchLog and not watchTmp and state.watchTimeoutMs == 0:
    discard process.waitForExit()
    if state.pollLog(emitLogs = false):
      return simFatal
    return simDone

  while process.running:
    if state.tick():
      return simFatal

    let currentTime = getMonoTime()
    if state.isStalled(currentTime):
      stderr.writeLine("[Monitor] Stall detected - no progress for ", (currentTime - state.lastProgressChange).inMilliseconds, " ms.")
      return simStalled

    if state.isTimedOut(currentTime):
      stderr.writeLine("[Monitor] Timeout after ", (currentTime - state.monitorStartTime).inMilliseconds, " ms - process still running.")
      return simTimeout

    if process.waitForExitNonDestructive(interval):
      break

  if state.tick():
    return simFatal

  if not watchLog and not watchTmp:
    if state.pollLog(emitLogs = false):
      return simFatal

  if state.watchTmp and state.lastSnapshot.isSome:
    let snapshot = state.lastSnapshot.get()
    if snapshot.progress.percent(snapshot.config) < 1.0:
      return simCancelled

  return simDone
