## Runs multiple trnrun processes with bounded concurrency.
##
## Workers send complete child-output lines through one shared channel. The
## coordinator routes valid TRNRun events to stdout, diagnostics to stderr, and
## emits one queue-owned completion marker per run.

when not defined(windows):
  {.error: "supervisor.nim is Windows-only.".}

import std/[json, os, sets, strutils, winlean]
import ./job
import ./protocol
import ./trnrun


const MessageCapacity = 256


type
  RunRequest* = object
    runId*: int
    deckFile*: string
    runnerPath*: string
    runnerArgs*: seq[string]

  SupervisionSummary* = object
    total*: int
    failed*: int

  QueueOutputError = object of CatchableError

  WorkerMessageKind = enum
    wmOutput
    wmFinished

  RunOutcome = object
    errorMessage: string

  WorkerMessage = object
    runId: int
    case kind: WorkerMessageKind
    of wmOutput:
      line: string
    of wmFinished:
      result: RunOutcome

  WorkerContext = object
    request: RunRequest
    messages: ptr Channel[WorkerMessage]

  ActiveWorker = ref object
    runId: int
    thread: Thread[WorkerContext]
    producedEvent: bool


proc emit(node: JsonNode) =
  try:
    stdout.writeLine($node)
    stdout.flushFile()
  except IOError:
    raise newException(
      QueueOutputError,
      "Could not write queue JSONL output: " & getCurrentExceptionMsg(),
    )

proc writeDiagnostic(runId: int, line: string) =
  try:
    stderr.writeLine("[run ", runId, "] ", line)
  except IOError:
    discard

proc runWorker(context: WorkerContext) {.thread.} =
  let onOutput = proc(line: string) {.gcsafe.} =
    context.messages[].send(WorkerMessage(
      kind: wmOutput,
      runId: context.request.runId,
      line: line,
    ))

  var errorMessage = ""
  try:
    runTrnrun(
      context.request.deckFile,
      context.request.runnerPath,
      context.request.runnerArgs,
      onOutput,
    )
  except CatchableError:
    errorMessage = getCurrentExceptionMsg()

  context.messages[].send(WorkerMessage(
    kind: wmFinished,
    runId: context.request.runId,
    result: RunOutcome(errorMessage: errorMessage),
  ))

proc startWorker(
    request: RunRequest,
    messages: ptr Channel[WorkerMessage],
): ActiveWorker =
  new(result)
  result.runId = request.runId

  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  createThread(
    result.thread,
    runWorker,
    WorkerContext(request: request, messages: messages),
  )
  {.pop.}

proc finish(worker: ActiveWorker) =
  joinThread(worker.thread)
  let nativeHandle = cast[Handle](worker.thread.handle)
  if nativeHandle != 0:
    discard closeHandle(nativeHandle)

proc findWorker(active: openArray[ActiveWorker], runId: int): int =
  for index, worker in active:
    if worker.runId == runId:
      return index
  return -1

proc superviseRuns*(
    requests: openArray[RunRequest],
    maxConcurrent: int,
): SupervisionSummary =
  ## Runs requests with bounded concurrency and emits their combined protocol.
  if maxConcurrent < 1:
    raise newException(ValueError, "maxConcurrent must be at least 1")

  result = SupervisionSummary(total: requests.len)
  if requests.len == 0:
    return

  var
    runIds = initHashSet[int]()
    deckPaths = initHashSet[string]()
    runnable: seq[RunRequest] = @[]

  for request in requests:
    if request.runId in runIds:
      raise newException(ValueError, "Duplicate runId: " & $request.runId)
    runIds.incl(request.runId)

    let deckPath = request.deckFile.absolutePath().normalizedPath().toLowerAscii()
    if deckPath in deckPaths:
      emit(exitEnvelope(
        request.runId,
        message = "The same deck cannot run concurrently: " & request.deckFile,
      ))
      inc result.failed
    else:
      deckPaths.incl(deckPath)
      runnable.add(request)

  if runnable.len == 0:
    return

  try:
    initJobGuard()
  except CatchableError:
    let message = "Could not initialize the child-process job guard: " &
      getCurrentExceptionMsg()
    for request in runnable:
      emit(exitEnvelope(request.runId, message))
      inc result.failed
    return

  var
    messages = default(Channel[WorkerMessage])
    nextRequest = 0
    active: seq[ActiveWorker] = @[]
  messages.open(MessageCapacity)

  while nextRequest < runnable.len or active.len > 0:
    while nextRequest < runnable.len and active.len < maxConcurrent:
      let request = runnable[nextRequest]
      inc nextRequest
      try:
        active.add(startWorker(request, addr messages))
      except CatchableError:
        emit(exitEnvelope(
          request.runId,
          message = "Could not start worker: " & getCurrentExceptionMsg(),
        ))
        inc result.failed

    if active.len == 0:
      continue

    let message = messages.recv()
    let index = active.findWorker(message.runId)
    if index < 0:
      raise newException(
        ValueError,
        "Message received for inactive runId: " & $message.runId,
      )

    case message.kind
    of wmOutput:
      try:
        emit(routeEvent(message.runId, message.line))
        active[index].producedEvent = true
      except JsonParsingError, ValueError:
        writeDiagnostic(message.runId, message.line)
    of wmFinished:
      var errorMessage = message.result.errorMessage
      if errorMessage.len == 0 and not active[index].producedEvent:
        errorMessage = "trnrun exited without producing an event"

      emit(exitEnvelope(message.runId, errorMessage))
      if errorMessage.len > 0:
        inc result.failed

      active[index].finish()
      active.del(index)

  # This process owns one channel for its lifetime. Explicit Channel.close
  # crashes Nim 2.2 ORC after receiving moved string messages.
