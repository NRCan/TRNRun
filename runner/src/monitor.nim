## monitor.nim - TRNSYS simulation monitor.
##
## Wraps a running TRNSYS process and produces structured events through an
## `EventSink` by polling two output files:
##
## - **`.tmp`**: a Type3830 temp file written periodically by TRNSYS,
##   containing the current simulation time and the fixed run parameters
##   (start, stop, step). Parsed into `CONFIG` and `PROGRESS` events.
## - **`.log`**: the TRNSYS message log, appended throughout the run.
##   Parsed into `LOG` events carrying severity, simulation time, unit/type
##   IDs, message code, and free-text fields.
##
## The supplied sink decides how each event is delivered. Event kinds:
##
## ```
## {"kind":"CONFIG",   "timestamp":…, "start":…, "stop":…, "step":…}
## {"kind":"PROGRESS", "timestamp":…, "time":…, "percent":…, "elapsed":…, "eta":…}
## {"kind":"LOG",      "timestamp":…, "severity":…, "time":…, …}
## ```
##
## `elapsed` and `eta` are in milliseconds. `percent` is in [0, 1].
##
## The main entry point is `monitor`. Call it after launching TRNSYS; it
## blocks until the process exits (or a fatal log entry, timeout, or stall
## is encountered) and returns a `SimMonitorResult` indicating the outcome.

import std/[os, osproc, strutils, options, times]
import ./events
import ./eventsink

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------
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
    timestamp: DateTime # Wall-clock time the file was read.
    time: float # Current simulation time in hours.

  TmpSnapshot = object
    ## A fully-parsed read of a Type3830 tmp file.
    config: SimConfig
    progress: SimProgress

  SimMonitorResult* = enum
    ## Final outcome of a monitored simulation run.
    monitorDone # Process exited and simulation reached 100 %.
    monitorCancelled # Process exited before simulation reached 100 %.
    monitorFatal # Process crashed, failed to start, or logged a fatal error.
    monitorTimeout # Process still running but did not finish in time.
    monitorStalled # Simulation time stopped advancing for longer than `stallTimeoutMs`.

  MonitorState = object
    ## Mutable book-keeping shared across polling ticks.
    tmpFile: string
    logFile: string
    startTime: Time
    watchLog: bool
    watchTmp: bool
    severity: LogSeverity
    logOffset: int64
    lastSnapshot: Option[TmpSnapshot]
    eventSink: EventSink
    watchTimeoutMs: int
    stallTimeoutMs: int
    lastProgressChange: Time

# ---------------------------------------------------------------------------
# Progress / tmp file
# ---------------------------------------------------------------------------
proc percent(self: SimProgress, config: SimConfig): float =
  ## Returns simulation progress in [0, 1] relative to `config`.
  if config.stop <= config.start: return 0.0
  clamp((self.time - config.start) / (config.stop - config.start), 0.0, 1.0)

proc elapsed(self: SimProgress, realStart: Time): float =
  ## Returns milliseconds elapsed since `realStart`.
  (self.timestamp.toTime() - realStart).inMilliseconds.float

proc eta(self: SimProgress, config: SimConfig, realStart: Time): float =
  ## Returns estimated milliseconds remaining, or 0 if progress is negligible.
  let pct = self.percent(config)
  if pct < 0.001: return 0.0
  let elap = self.elapsed(realStart)
  max(0.0, elap / pct - elap)

# ---------------------------------------------------------------------------
# Event conversion
# ---------------------------------------------------------------------------
proc configEvent(config: SimConfig): SimulationEvent =
  ## Creates an event from parsed run parameters.
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
    progress: SimProgress, config: SimConfig, realStart: Time
): SimulationEvent =
  ## Creates an event from a progress sample and its run context.
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
  ## Creates an event from a parsed TRNSYS log entry.
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

# ---------------------------------------------------------------------------
# Log parsing
# ---------------------------------------------------------------------------
const LogIgnoredValues = ["Not applicable", "Not available", "Not applicable or not available"]

# -- Utilities --
proc splitKeyValue(line: string): tuple[key, val: string] =
  ## Splits `line` at the first `:` into a key and value, both stripped.
  result = ("", "")
  let i = line.find(':')
  if i >= 0:
    result = (line[0 ..< i].strip(), line[i + 1 .. ^1].strip())

proc splitValue(line: string): string =
  ## Returns the value part of a `key : value` line.
  splitKeyValue(line).val

# -- Field parsers --
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

# -- Dispatch table --
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

# -- Helpers --
proc splitIntoBlocks(lines: openArray[string]): seq[seq[string]] =
  ## Groups log lines into blocks, each starting with a `***` header line.
  result = @[]
  var current: seq[string] = @[]

  for line in lines:
    if line.startsWith("***"):
      if current.len > 0:
        result.add(current)
      current = @[line]
    elif current.len > 0:
      current.add(line)

  if current.len > 0:
    result.add(current)

proc parseLogBlock(blck: openArray[string]): Option[SimLog] =
  ## Parses a single TRNSYS log block into a `SimLog`.
  if blck.len == 0 or not blck[0].startsWith("***"):
    return none(SimLog)

  var entry = SimLog(timestamp: now())

  for line in blck:
    let stripped = line.strip()
    let lower    = stripped.toLowerAscii()
    for (prefix, parser) in LogFieldParsers:
      if lower.startsWith(prefix):
        try:
          parser(stripped, entry)
        except ValueError:
          discard
        break

  if entry.message.isNone or entry.message.get().isEmptyOrWhitespace:
    return none(SimLog)

  result = some(entry)

proc readNewLines(offset: var int64, path: string): seq[string] =
  ## Reads newly appended lines from `path`, advancing `offset` and resetting it if the file was truncated.
  result = @[]
  var file = default(File)
  if not open(file, path, fmRead): return @[]
  defer: file.close()

  let size = file.getFileSize()

  if offset > size:
    stderr.writeLine("[Monitor] Log file truncated (", path, "); re-reading from start.")
    offset = 0
  if offset == size: return @[]

  file.setFilePos(offset)

  var line: string = ""
  while file.readLine(line):
    result.add(move(line))

  offset = file.getFilePos()

# -- Iterator --
iterator readLog(offset: var int64, path: string): SimLog =
  ## Yields log entries appended since the last call with the same `offset` (nothing if `path` doesn't exist yet).
  if fileExists(path):
    for blck in splitIntoBlocks(readNewLines(offset, path)):
      let parsed = parseLogBlock(blck)
      if parsed.isSome:
        yield parsed.get()

# ---------------------------------------------------------------------------
# tmp parsing
# ---------------------------------------------------------------------------
proc parseTmpContent(content: string): Option[TmpSnapshot] =
  ## Parses raw Type3830 tmp content of the form `currentTime, start, stop, step`.
  let parts = content.strip().split(',')
  if parts.len != 4:
    stderr.writeLine("[Monitor] Malformed tmp content (expected 4 fields, got ", parts.len, "): ", content.strip())
    return none(TmpSnapshot)

  try:
    let ts = now()
    return some TmpSnapshot(
      progress: SimProgress(timestamp: ts, time: parseFloat(parts[0].strip())),
      config: SimConfig(
        timestamp: ts,
        start: parseFloat(parts[1].strip()),
        stop:  parseFloat(parts[2].strip()),
        step:  parseFloat(parts[3].strip()),
      ),
    )
  except ValueError as e:
    stderr.writeLine("[Monitor] Failed to parse tmp fields: ", e.msg, " | content: ", content.strip())
    return none(TmpSnapshot)

proc readTmp(filepath: string): Option[TmpSnapshot] =
  ## Reads and parses a Type3830 tmp file; returns `none` on any I/O or parse error.
  try:
    return parseTmpContent(readFile(filepath))
  except CatchableError:
    return none(TmpSnapshot)

# ---------------------------------------------------------------------------
# Poll loop
# ---------------------------------------------------------------------------

proc pollTmp(state: var MonitorState) =
  ## Reads the tmp file and emits config/progress events as needed, skipping silently on I/O or parse errors.
  let snap = readTmp(state.tmpFile)
  if snap.isNone: return

  let current = snap.get()
  if state.lastSnapshot.isNone:
    state.eventSink(configEvent(current.config))

  if state.lastSnapshot.isNone or current.progress.time != state.lastSnapshot.get().progress.time:
    state.eventSink(progressEvent(current.progress, current.config, state.startTime))
    state.lastProgressChange = getTime()

  state.lastSnapshot = some(current)

proc pollLog(state: var MonitorState, emitLogs: bool = true): bool =
  ## Processes new log entries, emitting those at or above the severity threshold; returns `true` on a Fatal entry.
  for entry in readLog(state.logOffset, state.logFile):
    if emitLogs and entry.severity >= state.severity:
      state.eventSink(logEvent(entry))

    if entry.severity == Fatal:
      return true

  return false

proc tick(state: var MonitorState): bool =
  ## Runs one polling step; returns `true` if a fatal log entry was encountered.
  result = false
  if state.watchTmp: state.pollTmp()
  if state.watchLog: result = state.pollLog()

proc isTimedOut(state: MonitorState): bool =
  ## Returns `true` if the overall monitoring duration has exceeded `watchTimeoutMs`.
  state.watchTimeoutMs > 0 and (getTime() - state.startTime).inMilliseconds >= state.watchTimeoutMs

proc isStalled(state: MonitorState): bool =
  ## Returns `true` if simulation time has not advanced for `stallTimeoutMs` while under 100 % (requires `watchTmp`).
  if not state.watchTmp or state.stallTimeoutMs <= 0 or state.lastSnapshot.isNone:
    return false

  let snap = state.lastSnapshot.get()
  if snap.progress.percent(snap.config) >= 1.0:
    return false

  (getTime() - state.lastProgressChange).inMilliseconds >= state.stallTimeoutMs

proc clampTimeout(timeoutMs, pollMs: int, name: string): int =
  ## Raises `timeoutMs` to `pollMs` when smaller, since finer thresholds would trigger prematurely; 0 stays disabled.
  if timeoutMs > 0 and timeoutMs < pollMs:
    stderr.writeLine("[Monitor] ", name, " (", timeoutMs, " ms) is less than pollMs (",
                      pollMs, " ms); using ", pollMs, " ms instead.")
    return pollMs
  return timeoutMs

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
proc monitor*(
    process: Process,
    deckFile: string,
    startTime: Time,
    eventSink: EventSink,
    watchLog: bool = true,
    watchTmp: bool = true,
    pollMs: int = 100,
    severity: LogSeverity = Notice,
    watchTimeoutMs: int = 0,
    stallTimeoutMs: int = 0,
): SimMonitorResult =
  ## Polls TRNSYS output files until the process exits, emitting structured events.
  ##
  ## Watches the Type3830 `.tmp` file and the TRNSYS `.log` file of a
  ## running simulation, delivering structured events through `eventSink`.
  ## A final tick runs after the process exits to drain any output written
  ## just before termination.
  ##
  ## Parameters
  ## ----------
  ## process : Process
  ##     Running TRNSYS process, as returned by `launchTrnexe`.
  ## deckFile : string
  ##     Deck path; the `.tmp` and `.log` paths are derived from it.
  ## startTime : Time
  ##     Wall-clock launch time, used for `elapsed`/`eta` and the watch
  ##     timeout.
  ## eventSink : EventSink
  ##     Destination for structured events produced while monitoring.
  ## watchLog : bool, optional
  ##     Emit `LOG` events parsed from the `.log` file (default: true).
  ## watchTmp : bool, optional
  ##     Emit `CONFIG`/`PROGRESS` events parsed from the `.tmp` file
  ##     (default: true).
  ## pollMs : int, optional
  ##     Polling interval in milliseconds, clamped to >= 1 (default: 100).
  ## severity : LogSeverity, optional
  ##     Minimum severity a log entry must have to be emitted
  ##     (default: Notice).
  ## watchTimeoutMs : int, optional
  ##     Maximum total monitoring time in ms; 0 disables (default: 0).
  ## stallTimeoutMs : int, optional
  ##     Maximum time simulation time may stay unchanged before the run is
  ##     reported as stalled; 0 disables, requires `watchTmp` (default: 0).
  ##
  ## Returns
  ## -------
  ## SimMonitorResult
  ##     `monitorDone` on normal completion, `monitorCancelled` if the
  ##     process exited before reaching 100 %, `monitorFatal` on a fatal
  ##     log entry, `monitorTimeout` if `watchTimeoutMs` elapsed, or
  ##     `monitorStalled` if progress stopped for `stallTimeoutMs`.
  let interval = max(1, pollMs)
  var state = MonitorState(
    tmpFile:   deckFile.changeFileExt("tmp"),
    logFile:   deckFile.changeFileExt("log"),
    startTime: startTime,
    watchLog:  watchLog,
    watchTmp:  watchTmp,
    severity:  severity,
    eventSink: eventSink,
    watchTimeoutMs: clampTimeout(watchTimeoutMs, interval, "watchTimeoutMs"),
    stallTimeoutMs: clampTimeout(stallTimeoutMs, interval, "stallTimeoutMs"),
    lastProgressChange: startTime,
  )

  if not watchLog and not watchTmp:
    discard process.waitForExit()
    if state.pollLog(emitLogs = false): return monitorFatal
    return monitorDone

  while process.running:
    if state.tick(): return monitorFatal

    if state.isStalled():
      stderr.writeLine("[Monitor] Stall detected - no progress for ",
                        (getTime() - state.lastProgressChange).inMilliseconds, " ms.")
      return monitorStalled

    if state.isTimedOut():
      stderr.writeLine("[Monitor] Timeout after ",
                        (getTime() - state.startTime).inMilliseconds,
                        " ms - process still running.")
      return monitorTimeout

    sleep(interval)

  if state.tick(): return monitorFatal

  if state.watchTmp and state.lastSnapshot.isSome:
    let snap = state.lastSnapshot.get()
    if snap.progress.percent(snap.config) < 1.0:
      return monitorCancelled

  return monitorDone
