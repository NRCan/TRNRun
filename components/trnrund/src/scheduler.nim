## Schedules simulations and keeps their state in the store.
##
## The daemon runs one scheduler at a time, and every public operation runs on
## its owner thread. The owner launches each TRNRun itself and keeps its
## `Process`, so cancelling a running run kills it directly. Workers only read
## TRNRun output and post it as messages; the owner takes them in batches with
## `receive` and applies each one. A finished run frees its slot for the next
## queued run as its exit is applied.
##
## An `add` can wait for its run to start or finish. The scheduler keeps the
## request's `id` and, once the run gets there, a reply line `takeReplies`
## returns.
##
## Close the scheduler with `close` once `isDone`, so every worker is joined,
## or `abandon` it right before the process exits. The inbox is never closed:
## the stdin reader, the writer, and the workers left running by `abandon` may
## post to it until the process exits.

import std/[deques, options, osproc, tables]
import ./[events, messages, store, trnrun, validate, workerpool]

export InputError, store

const
  CancelReason = "cancelled by the client"
  ShutdownReason = "the daemon shut down"
  MaxBatch = 1_000 ## Most messages `receive` returns at once, bounding a batch's replies.

type
  Queued = object
    ## A stored run waiting for a slot, with what its launch needs.
    runId: int
    deckFile: string
    trnrunArgs: seq[string]

  Running = object
    ## A launched run, until its exit is applied.
    process: Process
    cancelReason: string ## Why it was killed; empty unless cancelled.

  Waiter = object
    ## An `add` that replies once its run reaches `state` or a later one.
    id: string ## The request's `id`, as JSON.
    state: SimulationState

  Scheduler* = ref object
    ## Queued and running simulations, plus the pool that reads their output.
    pool: WorkerPool
    inbox: Channel[Message] ## Never moves, being in a `ref`, so threads can point to it.
    store: Store

    trnrunPath: string
    maxConcurrent: int
    isShuttingDown: bool ## No more runs start; set by `requestShutdown` and `abandon`.
    isClosed: bool ## The workers are stopped or left; set by `close` and `abandon`.
    queue: Deque[Queued] ## Oldest first.
    running: Table[int, Running] ## At most `maxConcurrent`, by runId.
    waiters: Table[int, Waiter] ## By runId.
    replies: seq[string] ## Replies to waiters whose runs got there, until `takeReplies`.

proc answer(scheduler: Scheduler, runId: int) =
  ## Queues the reply to the `add` waiting on `runId` once the run reached the state it waits for.
  if runId notin scheduler.waiters or
      scheduler.store[runId].state < scheduler.waiters[runId].state:
    return
  var waiter = default(Waiter)
  discard scheduler.waiters.pop(runId, waiter)
  var reply = "{\"id\":" & waiter.id & ",\"ok\":true,\"runId\":" & $runId & ",\"run\":"
  reply.addJson(scheduler.store[runId])
  reply.add('}')
  scheduler.replies.add(reply)

proc launchQueued(scheduler: Scheduler, run: Queued) =
  ## Launches one queued run, or finishes it with the launch error if TRNRun cannot start.
  let launched =
    try:
      launch(run.runId, run.deckFile, scheduler.trnrunPath, run.trnrunArgs)
    except CatchableError as error:
      scheduler.store.finish(run.runId, none(int), error.msg)
      scheduler.answer(run.runId)
      return
  scheduler.store.start(run.runId)
  scheduler.answer(run.runId)
  scheduler.running[run.runId] = Running(process: launched.process)
  scheduler.pool.submit(
    Work(kind: wkRead, runId: run.runId, output: launched.output, process: launched.waitHandle)
  )

proc dispatch(scheduler: Scheduler) =
  ## Launches the longest-queued runs while a slot is free.
  while not scheduler.isShuttingDown and scheduler.running.len < scheduler.maxConcurrent and
      scheduler.queue.len > 0:
    scheduler.launchQueued(scheduler.queue.popFirst())

proc kill(run: var Running, reason: string) =
  ## Kills a running TRNRun once; its exit is applied as cancelled for `reason`.
  if run.cancelReason.len == 0 and run.process.running:
    run.cancelReason = reason
    run.process.kill()

proc finishExited(scheduler: Scheduler, message: Message) =
  ## Stores the outcome of a run whose output is drained, then closes its process.
  var run = default(Running)
  if not scheduler.running.pop(message.runId, run):
    return
  if run.cancelReason.len > 0:
    scheduler.store.cancel(message.runId, started = true, run.cancelReason)
  else:
    scheduler.store.finish(message.runId, message.exitCode, message.error)
  scheduler.answer(message.runId)
  try:
    run.process.close()
  except CatchableError:
    discard # The run is stored; a handle that fails to close changes nothing for it.

proc removeQueued(scheduler: Scheduler, runId: int): bool =
  ## Removes `runId` from the queue, keeping the others in order; whether it was there.
  var kept = initDeque[Queued]()
  for run in scheduler.queue:
    if run.runId != runId:
      kept.addLast(run)
  result = kept.len < scheduler.queue.len
  scheduler.queue = kept

# Public API

proc newScheduler*(trnrunPath: string, maxConcurrent: int): Scheduler =
  ## Starts a scheduler running `trnrunPath`; call `initJobGuard` first.
  if maxConcurrent < 1:
    raise newException(InputError, "'maxConcurrent' must be at least 1")
  let trnrunPath = validateFile(trnrunPath, "TRNRun")
  result = Scheduler(trnrunPath: trnrunPath, maxConcurrent: maxConcurrent, store: initStore())
  result.inbox.open()
  result.pool.start(maxConcurrent, addr result.inbox)

proc maxConcurrent*(scheduler: Scheduler): int {.inline.} =
  ## Most simulations running at once.
  scheduler.maxConcurrent

proc store*(scheduler: Scheduler): lent Store {.inline.} =
  ## Every run not released yet, with its logs.
  scheduler.store

proc requestInbox*(scheduler: Scheduler): ptr Channel[Message] {.inline.} =
  ## Inbox address for the thread that posts `mkRequest` and `mkClosed`.
  addr scheduler.inbox

proc receive*(scheduler: Scheduler): seq[Message] =
  ## Waits for the next message, then also returns those already waiting.
  result = @[scheduler.inbox.recv()]
  while result.len < MaxBatch:
    let (available, message) = scheduler.inbox.tryRecv()
    if not available:
      break
    result.add(message)

proc apply*(scheduler: Scheduler, message: Message) =
  ## Applies one worker message; an exit frees a slot for the next queued run.
  case message.kind
  of mkOutput:
    let event = parseEventLine(message.line)
    if event.isSome:
      scheduler.store.record(message.runId, event.get())
  of mkExited:
    scheduler.finishExited(message)
    scheduler.dispatch()
  of mkRequest, mkClosed:
    discard

proc add*(
    scheduler: Scheduler,
    deckFile: string,
    trnrunArgs: seq[string] = @[],
    label = none(string),
    waitFor = ssQueued,
    replyId = "",
): int =
  ## Validates, stores and queues a run, launching it if a slot is free; returns its `runId`.
  ##
  ## With `waitFor` past `QUEUED`, `takeReplies` later returns the reply for
  ## `replyId`, the request's `id` as JSON, once the run reaches `waitFor` or a
  ## later state.
  if scheduler.isShuttingDown:
    raise newException(InputError, "The daemon is shutting down")
  validateTrnrunArgs(trnrunArgs)
  let deckFile = validateDeck(deckFile)
  result = scheduler.store.submit(deckFile, trnrunArgs, label)
  if waitFor > ssQueued:
    scheduler.waiters[result] = Waiter(id: replyId, state: waitFor)
  scheduler.queue.addLast(Queued(runId: result, deckFile: deckFile, trnrunArgs: trnrunArgs))
  scheduler.dispatch()

proc takeReplies*(scheduler: Scheduler): seq[string] =
  ## The replies to waiting adds whose runs got there since the last call, in that order.
  result = @[]
  swap(result, scheduler.replies)

proc cancel*(scheduler: Scheduler, runId: int) =
  ## Stops `runId` unless it already finished; `InputError` if unknown, `ValueError` once closed.
  if scheduler.isClosed:
    raise newException(ValueError, "The scheduler is closed")
  if runId in scheduler.running:
    scheduler.running[runId].kill(CancelReason)
  elif scheduler.removeQueued(runId):
    scheduler.store.cancel(runId, started = false, CancelReason)
    scheduler.answer(runId)
  elif runId notin scheduler.store:
    raise newException(InputError, "Unknown runId: " & $runId)

proc release*(scheduler: Scheduler, runId: int) =
  ## Deletes a finished run with its logs, skipping an unknown one; see `store.release`.
  scheduler.store.release(runId)

proc requestShutdown*(scheduler: Scheduler, cancelRunning = false) =
  ## Rejects new runs and cancels queued ones, and running ones too with `cancelRunning`.
  if scheduler.isClosed:
    return
  if not scheduler.isShuttingDown:
    scheduler.isShuttingDown = true
    for run in scheduler.queue:
      scheduler.store.cancel(run.runId, started = false, ShutdownReason)
      scheduler.answer(run.runId)
    scheduler.queue.clear()
  if cancelRunning:
    for run in scheduler.running.mvalues:
      run.kill(ShutdownReason)

proc isDone*(scheduler: Scheduler): bool {.inline.} =
  ## Whether a requested shutdown has no running run left to wait for.
  scheduler.isShuttingDown and scheduler.running.len == 0

proc close*(scheduler: Scheduler) =
  ## Joins every worker. Call once `isDone`.
  if scheduler.isClosed:
    return
  scheduler.isClosed = true
  scheduler.pool.shutdown()

proc abandon*(scheduler: Scheduler) =
  ## Kills every running TRNRun and stops without joining workers or answering
  ## waiting adds; for exit only.
  if scheduler.isClosed:
    return
  scheduler.isShuttingDown = true
  scheduler.isClosed = true
  for run in scheduler.running.mvalues:
    run.process.kill() # The Job Object would kill them at exit anyway.
  scheduler.queue.clear()
  scheduler.running.clear() # Not closed: workers may still be reading their output.
