## TRNSYS simulation monitor.
##
## Wraps a running TRNSYS process and streams structured JSON events to stdout
## by polling two output files:
##
## - **`.tmp`**: a Type3830 temp file written periodically by TRNSYS,
##   containing the current simulation time and the fixed run parameters
##   (start, stop, step). Parsed into `CONFIG` and `PROGRESS` events.
## - **`.log`**: the TRNSYS message log, appended throughout the run.
##   Parsed into `LOG` events carrying severity, simulation time, unit/type
##   IDs, message code, and free-text fields.
##
## Each event is a self-contained JSON object written as a single line.
## Event kinds:
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


import std/[os, osproc, strutils, options, times, json, math]

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------
type
  LogSeverity* = enum
    ## Severity of a TRNSYS log entry.
    Notice
    Warning
    Fatal

  SimLog = object
    ## A single parsed TRNSYS log entry.
    timestamp: DateTime # Wall-clock time the entry was parsed.
    severity: LogSeverity # Severity of the message.
    time: float # Simulation time in hours.
    unitID: int # TRNSYS unit ID; 0 if not applicable.
    typeID: int # TRNSYS type ID; 0 if not applicable.
    messageCode: int # TRNSYS message code; 0 if not applicable.
    message: string # TRNSYS message text.
    information: string # TRNSYS additional information.

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
    monitorDone # Process exited and simulation reached 100%.
    monitorCancelled # Process exited before simulation reached 100%.
    monitorFatal # Process crashed or exited prematurely.
    monitorTimeout # Process still running but did not finish in time.
    monitorStalled # Simulation time stopped advancing for longer than stallTimeoutMs.

  MonitorState = object
    tmpFile: string
    logFile: string
    startTime: Time
    watchLog: bool
    watchTmp: bool
    severity: LogSeverity
    logOffset: int64
    lastSnapshot: Option[TmpSnapshot]
    jsonlPath: string
    watchTimeoutMs: int
    stallTimeoutMs: int
    lastProgressChange: Time

# ---------------------------------------------------------------------------
# Progress / tmp file
# ---------------------------------------------------------------------------
proc percent(self: SimProgress, config: SimConfig): float =
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
# JSON serialisation
# ---------------------------------------------------------------------------
const IsoFmt: string = "yyyy-MM-dd'T'HH:mm:ss"

proc toJson*(self: SimConfig): JsonNode =
  result = newJObject()
  result["kind"] = %"CONFIG"
  result["timestamp"] = %self.timestamp.format(IsoFmt)
  result["start"] = %self.start
  result["stop"] = %self.stop
  result["step"] = %self.step

proc toJson*(self: SimProgress, config: SimConfig, realStart: Time): JsonNode =
  result = newJObject()
  result["kind"] = %"PROGRESS"
  result["timestamp"] = %self.timestamp.format(IsoFmt)
  result["time"] = %self.time.round(2)
  result["percent"] = %self.percent(config).round(4)
  result["elapsed"] = %self.elapsed(realStart).round(2)
  result["eta"] = %self.eta(config, realStart).round(2)

proc toJson*(self: SimLog): JsonNode =
  result = newJObject()
  result["kind"] = %"LOG"
  result["timestamp"] = %self.timestamp.format(IsoFmt)
  result["severity"] = %($self.severity)
  result["time"] = %self.time
  if self.unitID != 0:
    result["unitID"] = %self.unitID
  if self.typeID != 0:
    result["typeID"] = %self.typeID
  if self.messageCode != 0:
    result["messageCode"] = %self.messageCode
  if self.message.len > 0:
    result["message"] = %self.message
  if self.information.len > 0:
    result["information"] = %self.information

# ---------------------------------------------------------------------------
# Log parsing
# ---------------------------------------------------------------------------
const LogIgnoredValues = ["Not applicable", "Not available", "Not applicable or not available"]

# -- Utilities --
proc splitKeyValue(line: string): tuple[key, val: string] =
  ## Splits `line` at the first `:` into a key and value, both stripped.
  let i = line.find(':')
  if i >= 0:
    result = (line[0 ..< i].strip(), line[i + 1 .. ^1].strip())

proc splitValue(line: string): string = splitKeyValue(line).val

# -- Field parsers --
proc parseHeader(line: string, log: var SimLog) =
  ## Parses `*** <severity> at time : <time>`.
  let (key, val) = splitKeyValue(line)

  log.severity =
    if "Warning" in key: Warning
    elif "Fatal" in key: Fatal
    else: Notice

  log.time = parseFloat(val)

proc parseUnitID(line: string, log: var SimLog) =
  ## Parses `Generated by Unit : <unitID>`.
  let val = splitValue(line)
  if val notin LogIgnoredValues:
    log.unitID = parseInt(val)

proc parseTypeID(line: string, log: var SimLog) =
  ## Parses `Generated by Type : <typeID>`.
  let val = splitValue(line)
  if val notin LogIgnoredValues:
    log.typeID = parseInt(val)

proc parseMessageCode(line: string, log: var SimLog) =
  ## Parses `TRNSYS Message <code> : <message>`.
  let (key, val) = splitKeyValue(line)

  let tokens = key.splitWhitespace()
  if tokens.len > 0:
    log.messageCode = parseInt(tokens[^1])

  if val notin LogIgnoredValues:
    log.message = val

proc parseMessage(line: string, log: var SimLog) =
  ## Parses `Message : <message>`.
  let val = splitValue(line)
  if val notin LogIgnoredValues:
    log.message = val

proc parseInformation(line: string, log: var SimLog) =
  ## Parses `Reported information : <information>`.
  let val = splitValue(line)
  if val notin LogIgnoredValues:
    log.information = val

# -- Dispatch table --
type LogFieldParser = proc(line: string, log: var SimLog) {.noSideEffect, gcsafe.}

const LogFieldParsers: array[7, tuple[prefix: string, parser: LogFieldParser]] = [
  ("***", parseHeader),
  ("generated by unit", parseUnitID),
  ("generated by type", parseTypeID),
  ("trnsys message", parseMessageCode),
  ("reported information", parseInformation),
  ("information", parseInformation),
  ("message", parseMessage),
]

# -- Helpers --
proc splitIntoBlocks(lines: openArray[string]): seq[seq[string]] =
  ## Groups log lines into blocks, each starting with a `***` header line.
  var current: seq[string]

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
        parser(stripped, entry)
        break

  if entry.message.isEmptyOrWhitespace:
    return none(SimLog)

  result = some(entry)

proc readNewLines(offset: var int64, path: string): seq[string] =
  ## Reads only newly appended lines from `path`, advancing `offset`.
  ## Resets the offset if the file was truncated.
  var file: File
  if not open(file, path, fmRead): return @[]
  defer: file.close()

  let size = file.getFileSize()

  if offset > size:
    stderr.writeLine("[Monitor] Log file truncated (", path, "); re-reading from start.")
    offset = 0
  if offset == size: return @[]

  file.setFilePos(offset)

  var line: string
  while file.readLine(line):
    result.add(line)

  offset = file.getFilePos()

# -- Iterator --
iterator readLog(offset: var int64, path: string): SimLog =
  ## Yields newly appended TRNSYS log entries since the last call.
  ## Pass the same `offset` variable on every call to advance the read position.
  ## Yields nothing if `path` does not yet exist.
  if fileExists(path):
    for blck in splitIntoBlocks(readNewLines(offset, path)):
      let parsed = parseLogBlock(blck)
      if parsed.isSome:
        yield parsed.get()

# ---------------------------------------------------------------------------
# tmp parsing
# ---------------------------------------------------------------------------
proc parseTmpContent(content: string): Option[TmpSnapshot] =
  ## Parses a raw Type3830 tmp file string.
  ## Expected format: `currentTime, start, stop, step`
  let parts = content.strip().split(',')
  if parts.len != 4:
    stderr.writeLine("[Monitor] Malformed tmp content (expected 4 fields, got ",parts.len, "): ", content.strip())
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
  ## Reads and parses a Type3830 tmp file. Returns none on any I/O or parse
  ## error, including when TRNSYS holds an exclusive write lock on the file.
  try:
    return parseTmpContent(readFile(filepath))
  except CatchableError:
    return none(TmpSnapshot)

# ---------------------------------------------------------------------------
# Poll loop
# ---------------------------------------------------------------------------
proc emit(state: var MonitorState, line: string) =
  ## Writes a line to stdout and the JSONL file, flushing both immediately.
  echo line
  stdout.flushFile()

  if state.jsonlPath.len > 0:
    let f = open(state.jsonlPath, fmAppend)
    f.writeLine(line)
    f.close()

proc pollTmp(state: var MonitorState) =
  ## Reads the tmp file and emits config/progress updates as needed.
  ## Skips silently on any I/O or parse error.
  let snap = readTmp(state.tmpFile)
  if snap.isNone: return

  let current = snap.get()
  if state.lastSnapshot.isNone:
    state.emit($current.config.toJson())

  if state.lastSnapshot.isNone or current.progress.time != state.lastSnapshot.get().progress.time:
    state.emit($current.progress.toJson(current.config, state.startTime))
    state.lastProgressChange = getTime()

  state.lastSnapshot = some(current)

proc pollLog(state: var MonitorState, emitLogs: bool = true): bool =
  ## Processes new log entries.
  ## Returns `true` if a Fatal entry is encountered.
  for entry in readLog(state.logOffset, state.logFile):
    if emitLogs and entry.severity >= state.severity:
      state.emit($entry.toJson())

    if entry.severity == Fatal:
      return true

  return false

proc tick(state: var MonitorState): bool =
  ## Runs one polling step. Returns `true` if a fatal condition is encountered.
  if state.watchTmp: state.pollTmp()
  if state.watchLog: result = state.pollLog()

proc isTimedOut(state: MonitorState): bool =
  ## Returns `true` if the overall monitoring duration has exceeded `watchTimeoutMs`.
  state.watchTimeoutMs > 0 and (getTime() - state.startTime).inMilliseconds >= state.watchTimeoutMs

proc isStalled(state: MonitorState): bool =
  ## Returns `true` if simulation time has not advanced for `stallTimeoutMs`.
  ## Always `false` if `watchTmp` is disabled, since progress can't be observed.
  if not state.watchTmp or state.stallTimeoutMs <= 0 or state.lastSnapshot.isNone:
    return false

  let snap = state.lastSnapshot.get()
  if snap.progress.percent(snap.config) >= 1.0:
    return false

  (getTime() - state.lastProgressChange).inMilliseconds >= state.stallTimeoutMs

proc clampTimeout(timeoutMs, pollMs: int, name: string): int =
  ## Raises `timeoutMs` to `pollMs` if smaller, since a threshold finer than
  ## the polling interval can't be checked meaningfully and would trigger
  ## prematurely. Disabled (0) timeouts pass through unchanged.
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
    watchLog: bool = true,
    watchTmp: bool = true,
    pollMs: int = 100,
    severity: LogSeverity = Notice,
    watchTimeoutMs: int = 0,
    stallTimeoutMs: int = 0,
    jsonlPath: string = "",
): SimMonitorResult =
  ## Polls TRNSYS output files until the process exits, streaming JSON events.
  ## A final tick runs after exit to drain any output written before termination.
  var state = MonitorState(
    tmpFile:   deckFile.changeFileExt("tmp"),
    logFile:   deckFile.changeFileExt("log"),
    startTime: startTime,
    watchLog:  watchLog,
    watchTmp:  watchTmp,
    severity:  severity,
    jsonlPath: jsonlPath,
    watchTimeoutMs: clampTimeout(watchTimeoutMs, pollMs, "watchTimeoutMs"),
    stallTimeoutMs: clampTimeout(stallTimeoutMs, pollMs, "stallTimeoutMs"),
    lastProgressChange: startTime,
  )

  if not watchLog and not watchTmp:
    discard process.waitForExit()
    if state.pollLog(emitLogs = true): return monitorFatal
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

    sleep(pollMs)

  if state.tick(): return monitorFatal

  if state.watchTmp and state.lastSnapshot.isSome:
    let snap = state.lastSnapshot.get()
    if snap.progress.percent(snap.config) < 1.0:
      return monitorCancelled

  return monitorDone
