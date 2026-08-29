## Concurrent process supervisor for TRNRun simulations.
##
## Each accepted deck is assigned a job ID and run by a bounded worker pool.
## Child JSONL events are enriched with queue routing metadata and written through
## one synchronized stdout boundary. If a child cannot provide a terminal event,
## the queue emits one on its behalf.

import std/[
  json,
  locks,
  os,
  osproc,
  parseutils,
  sets,
  streams,
  strutils,
  times,
]
import ./jobguard

const
  NimblePkgVersion {.strdefine.} = "unknown"
  TerminalStatuses = ["DONE", "CANCELLED", "ERROR", "TIMEOUT", "STALLED"]
  MaxDiagnostics = 20


type
  Job = object
    id: string
    deckFile: string
    runnerPath: string
    runnerArgs: seq[string]

  QueueOptions = object
    runnerPath: string
    maxConcurrent: int
    runnerArgs: seq[string]
    deckFiles: seq[string]


var
  outputLock: Lock
  resultLock: Lock
  jobChannel: Channel[Job]
  queueSequence = 0
  failedJobs = 0


proc eventTimestamp(): string =
  now().format("yyyy-MM-dd'T'HH:mm:ss")

proc isTerminal(status: string): bool =
  status.toUpperAscii() in TerminalStatuses

proc writeDiagnostic(jobId, message: string) =
  withLock outputLock:
    stderr.writeLine("[job ", jobId, "] ", message)

proc emit(job: Job, node: JsonNode) =
  ## Adds queue routing metadata and writes one complete, flushed JSON line.
  withLock outputLock:
    inc queueSequence
    node["jobId"] = %job.id
    node["deckFile"] = %job.deckFile
    node["queueSeq"] = %queueSequence
    stdout.writeLine($node)
    stdout.flushFile()

proc statusNode(status: string, exitCode: int = -1): JsonNode =
  result = newJObject()
  result["kind"] = %"STATUS"
  result["timestamp"] = %eventTimestamp()
  result["status"] = %status
  result["source"] = %"trnrunq"
  if exitCode >= 0:
    result["exitCode"] = %exitCode

proc emitQueued(job: Job) =
  job.emit(statusNode("QUEUED"))

proc emitError(job: Job, message: string, exitCode: int, diagnostic = "") =
  ## Emits a terminal ERROR carrying one human-readable failure message.
  let node = statusNode("ERROR", exitCode)
  node["error"] =
    if diagnostic.len > 0: %(message & ": " & diagnostic) else: %message
  job.emit(node)

proc markFailed() =
  withLock resultLock:
    inc failedJobs

proc rememberDiagnostic(diagnostics: var seq[string], line: string) =
  if diagnostics.len == MaxDiagnostics:
    diagnostics.delete(0)
  diagnostics.add(line)

proc diagnosticSummary(diagnostics: openArray[string]): string =
  diagnostics.join("\n")

proc childEvent(line: string): JsonNode =
  result = parseJson(line)
  if result.kind != JObject:
    raise newException(ValueError, "child event is not a JSON object")
  if not result.hasKey("kind") or result["kind"].kind != JString:
    raise newException(ValueError, "child event has no string 'kind' field")

proc runJob(job: Job) =
  var
    process: Process = nil
    terminalSeen = false
    terminalStatus = ""
    pendingDone: JsonNode = nil
    diagnostics: seq[string] = @[]
    observedExitCode = -1

  try:
    try:
      process = startProcess(
        job.runnerPath,
        args = @[job.deckFile] & job.runnerArgs,
        options = {poStdErrToStdOut},
      )
    except OSError, IOError:
      job.emitError(
        "Could not start trnrun: '" & job.runnerPath & "'",
        1,
        diagnostic = getCurrentExceptionMsg(),
      )
      markFailed()
      return

    let output = process.outputStream
    var line = ""
    while output.readLine(line):
      if line.len == 0:
        continue

      var node: JsonNode = nil
      try:
        node = childEvent(line)
      except JsonParsingError, ValueError:
        diagnostics.rememberDiagnostic(line)
        writeDiagnostic(job.id, line)
        continue

      var status = ""
      if node["kind"].getStr().toUpperAscii() == "STATUS" and
          node.hasKey("status") and node["status"].kind == JString:
        status = node["status"].getStr().toUpperAscii()

      if status.isTerminal():
        if terminalSeen:
          writeDiagnostic(job.id, "Ignored duplicate terminal status " & status)
          continue

        terminalSeen = true
        terminalStatus = status

        # A successful child should exit immediately. Holding DONE until then
        # lets the queue reconcile an abnormal wrapper exit without emitting a
        # second terminal event. TIMEOUT/STALLED may intentionally wait for
        # TrnEXE after reporting their terminal outcome, so emit those at once.
        if status == "DONE":
          pendingDone = node
        else:
          job.emit(node)
      elif terminalSeen:
        writeDiagnostic(job.id, "Ignored child event after terminal status")
      else:
        job.emit(node)

    observedExitCode = process.waitForExit()

    if not terminalSeen:
      job.emitError(
        "trnrun exited without emitting a terminal status",
        if observedExitCode >= 0: observedExitCode else: 1,
        diagnostic = diagnostics.diagnosticSummary(),
      )
      markFailed()
    elif terminalStatus == "DONE":
      if observedExitCode == 0:
        if not pendingDone.hasKey("exitCode"):
          pendingDone["exitCode"] = %observedExitCode
        job.emit(pendingDone)
      else:
        job.emitError(
          "trnrun reported DONE but exited unsuccessfully",
          if observedExitCode >= 0: observedExitCode else: 1,
          diagnostic = diagnostics.diagnosticSummary(),
        )
        markFailed()
    else:
      markFailed()
  finally:
    if process != nil:
      try:
        process.close()
      except CatchableError:
        discard

proc worker() {.thread.} =
  while true:
    let job = jobChannel.recv()
    if job.id.len == 0:
      break
    runJob(job)

proc optionParts(argument: string): tuple[key, value: string, hasValue: bool] =
  let colon = argument.find(':', 2)
  let equals = argument.find('=', 2)
  var separator = -1

  if colon >= 0 and equals >= 0:
    separator = min(colon, equals)
  elif colon >= 0:
    separator = colon
  else:
    separator = equals

  if separator < 0:
    return (argument[2 .. ^1], "", false)

  (
    argument[2 ..< separator],
    argument[separator + 1 .. ^1],
    true,
  )

proc defaultQueueOptions(): QueueOptions =
  QueueOptions(
    runnerPath: getAppDir() / "trnrun.exe",
    maxConcurrent: max(countProcessors() - 1, 1),
    runnerArgs: @[],
    deckFiles: @[],
  )

proc writeHelp() =
  echo """trnrunq - run TRNRun simulations concurrently

Usage:
  trnrunq [queue options] deckFile [deckFile ...] [runner options]

Queue options:
  -h, --help                Show this help and exit
  -v, --version             Show version and exit
  --runnerPath:PATH         trnrun executable (default: beside trnrunq)
  --maxConcurrent:N         Maximum simultaneous runners (default: CPU count - 1)

All other --options are forwarded unchanged to every trnrun process.
Every stdout line is JSON. Events include jobId, deckFile, and queueSeq."""

proc parseCommandLine(options: var QueueOptions): int =
  var forwardingOnly = false

  for argument in commandLineParams():
    if argument == "--":
      forwardingOnly = true
      continue

    if not forwardingOnly and argument in ["-h", "--help"]:
      writeHelp()
      return 1
    if not forwardingOnly and argument in ["-v", "--version"]:
      echo NimblePkgVersion
      return 1

    if not forwardingOnly and argument.startsWith("--"):
      let (key, value, hasValue) = optionParts(argument)
      case key
      of "runnerPath":
        if not hasValue or value.len == 0:
          stderr.writeLine("Error: --runnerPath requires a value")
          return -1
        options.runnerPath = value
      of "maxConcurrent":
        if not hasValue or value.len == 0:
          stderr.writeLine("Error: --maxConcurrent requires a value")
          return -1
        var parsed = 0
        if parseInt(value, parsed) != value.len or parsed < 1:
          stderr.writeLine("Error: --maxConcurrent must be an integer of at least 1")
          return -1
        options.maxConcurrent = parsed
      of "deckFile":
        stderr.writeLine("Error: trnrunq accepts decks as positional arguments")
        return -1
      else:
        options.runnerArgs.add(argument)
    elif argument.startsWith("-"):
      options.runnerArgs.add(argument)
    elif forwardingOnly:
      options.runnerArgs.add(argument)
    else:
      options.deckFiles.add(argument)

  if options.deckFiles.len == 0:
    stderr.writeLine("Error: at least one deck file is required")
    return -1

  return 0

proc normalizedAbsolutePath(path: string): string =
  path.absolutePath().normalizedPath()

{.push warning[GcUnsafe]: off.}
proc main(): int =
  # This procedure owns scheduler collections before and after worker joins.
  # Nim 2.2 otherwise reports GcUnsafe from generic seq/HashSet internals here.
  var options = defaultQueueOptions()
  let parseResult = parseCommandLine(options)
  if parseResult > 0:
    return 0
  if parseResult < 0:
    return 2

  initLock(outputLock)
  initLock(resultLock)
  defer:
    deinitLock(resultLock)
    deinitLock(outputLock)

  try:
    initJobGuard()
  except OSError as error:
    stderr.writeLine(
      "Warning: orphan guard unavailable; child runners may outlive trnrunq: ",
      error.msg,
    )

  let runnerPath = options.runnerPath.normalizedAbsolutePath()
  var
    runnable: seq[Job] = @[]
    seenDecks = initHashSet[string]()

  for index, suppliedDeck in options.deckFiles:
    let deckFile = suppliedDeck.normalizedAbsolutePath()
    let job = Job(
      id: $(index + 1),
      deckFile: deckFile,
      runnerPath: runnerPath,
      runnerArgs: options.runnerArgs,
    )
    job.emitQueued()

    if not fileExists(deckFile):
      job.emitError("Deck file does not exist: '" & deckFile & "'", 2)
      markFailed()
      continue

    if deckFile.splitFile().ext.toLowerAscii() notin [".dck", ".trd"]:
      job.emitError(
        "Expected a .dck or .trd deck file, got: '" & deckFile & "'",
        2,
      )
      markFailed()
      continue

    let deckKey = deckFile.toLowerAscii()
    if deckKey in seenDecks:
      job.emitError(
        "The same deck cannot run concurrently in one queue: '" &
          deckFile & "'",
        2,
      )
      markFailed()
      continue
    seenDecks.incl(deckKey)

    if not fileExists(runnerPath):
      job.emitError(
        "trnrun executable does not exist: '" & runnerPath & "'",
        1,
      )
      markFailed()
      continue

    runnable.add(job)

  if runnable.len > 0:
    let workerCount = min(options.maxConcurrent, runnable.len)
    jobChannel.open(max(runnable.len + workerCount, 1))
    defer: jobChannel.close()

    var workers = newSeq[Thread[void]](workerCount)
    for index in 0 ..< workerCount:
      createThread(workers[index], worker)

    for job in runnable:
      jobChannel.send(job)
    for _ in 0 ..< workerCount:
      jobChannel.send(Job())

    for index in 0 ..< workerCount:
      joinThread(workers[index])

  if failedJobs == 0: 0 else: 1
{.pop.}

when isMainModule:
  quit(main())
