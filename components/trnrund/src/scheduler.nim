## Schedules simulations and saves their state to the database.
##
## The daemon runs one scheduler at a time, and every public operation runs on
## its owner thread. The owner launches each TRNRun itself and keeps its
## `Process`, so cancelling a running run kills it directly. Workers only read
## TRNRun output and post it as messages; the owner takes them in batches with
## `receive` and applies each batch inside one `atomically` block, so readers
## see a batch's changes at once and every save is not its own commit. A
## finished run frees its slot for the next queued run as its exit is applied.
##
## Close the scheduler with `close` once `isDone`, so every worker is joined,
## or `abandon` it right before the process exits. The inbox is never closed:
## the stdin reader, the writer, and the workers left running by `abandon` may
## post to it until the process exits.
##
## The database is the record of every run; the scheduler only keeps in memory
## the runs waiting for a slot and those running, which a new daemon never
## resumes anyway.

import std/[deques, options, osproc, tables]
import ./[database, events, messages, trnrun, validate, workerpool]

export InputError

const
  CancelReason = "cancelled by the client"
  ShutdownReason = "the daemon shut down"
  DisconnectReason = "the client disconnected"
  MaxBatch = 1_000 ## Most messages `receive` returns at once, bounding a batch's transaction.

type
  Queued = object
    ## A saved run waiting for a slot, with what its launch needs.
    runId: int
    deckFile: string
    trnrunArgs: seq[string]

  Running = object
    ## A launched run, until its exit is applied.
    process: Process
    cancelReason: string ## Why it was killed; empty unless cancelled.

  Scheduler* = ref object
    ## Queued and running simulations, plus the pool that reads their output.
    pool: WorkerPool
    inbox: Channel[Message] ## Never moves, being in a `ref`, so threads can point to it.
    database: Database

    trnrunPath: string
    maxConcurrent: int
    isShuttingDown: bool ## No more runs start; set by `requestShutdown` and `abandon`.
    isClosed: bool ## The database is closed; set by `close` and `abandon`.
    queue: Deque[Queued] ## Oldest first.
    running: Table[int, Running] ## At most `maxConcurrent`, by runId.

proc launchQueued(scheduler: Scheduler, run: Queued) =
  ## Launches one queued run, or finishes it with the launch error if TRNRun cannot start.
  let launched =
    try:
      launch(run.runId, run.deckFile, scheduler.trnrunPath, run.trnrunArgs)
    except CatchableError as error:
      scheduler.database.finish(run.runId, none(int), error.msg)
      return
  scheduler.database.start(run.runId)
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
  ## Saves the outcome of a run whose output is drained, then closes its process.
  var run = default(Running)
  if not scheduler.running.pop(message.runId, run):
    return
  if run.cancelReason.len > 0:
    scheduler.database.cancel(message.runId, started = true, run.cancelReason)
  else:
    scheduler.database.finish(message.runId, message.exitCode, message.error)
  try:
    run.process.close()
  except CatchableError:
    discard # The run is saved; a handle that fails to close changes nothing for it.

proc removeQueued(scheduler: Scheduler, runId: int): bool =
  ## Removes `runId` from the queue, keeping the others in order; whether it was there.
  var kept = initDeque[Queued]()
  for run in scheduler.queue:
    if run.runId != runId:
      kept.addLast(run)
  result = kept.len < scheduler.queue.len
  scheduler.queue = kept

# Public API

proc newScheduler*(trnrunPath: string, maxConcurrent: int, databasePath: string): Scheduler =
  ## Starts a scheduler running `trnrunPath`, saving to `databasePath`; call `initJobGuard` first.
  if maxConcurrent < 1:
    raise newException(InputError, "'maxConcurrent' must be at least 1")
  let trnrunPath = validateFile(trnrunPath, "TRNRun")
  result = Scheduler(
    trnrunPath: trnrunPath, maxConcurrent: maxConcurrent, database: openDatabase(databasePath)
  )
  result.inbox.open()
  result.pool.start(maxConcurrent, addr result.inbox)

proc databasePath*(scheduler: Scheduler): string {.inline.} =
  ## Absolute path of the database clients read.
  scheduler.database.path

proc sessionId*(scheduler: Scheduler): int {.inline.} =
  ## This daemon's session, recorded on every run it adds.
  scheduler.database.sessionId

proc savedRevision*(scheduler: Scheduler): int =
  ## Largest revision a run holds: the latest change readers can reach.
  scheduler.database.savedRevision

proc lastLogId*(scheduler: Scheduler): int =
  ## Largest `log_id`, or 0 without logs.
  scheduler.database.lastLogId

proc contains*(scheduler: Scheduler, runId: int): bool =
  ## Whether `runId` was ever saved, by this daemon or an earlier one.
  runId in scheduler.database

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

template atomically*(scheduler: Scheduler, body: untyped) =
  ## Applies `body` in one database transaction; readers see its changes at once.
  scheduler.database.transaction:
    body

proc apply*(scheduler: Scheduler, message: Message) =
  ## Applies one worker message; an exit frees a slot for the next queued run.
  case message.kind
  of mkOutput:
    let event = parseEventLine(message.line)
    if event.isSome:
      scheduler.database.record(message.runId, event.get())
  of mkExited:
    scheduler.finishExited(message)
    scheduler.dispatch()
  of mkRequest, mkClosed:
    discard

proc add*(
    scheduler: Scheduler, deckFile: string, trnrunArgs: seq[string] = @[], label = none(string)
): int =
  ## Validates, saves and queues a run, launching it if a slot is free; returns its `run_id`.
  if scheduler.isShuttingDown:
    raise newException(InputError, "The daemon is shutting down")
  validateTrnrunArgs(trnrunArgs)
  let deckFile = validateDeck(deckFile)
  result = scheduler.database.submit(deckFile, trnrunArgs, label)
  scheduler.queue.addLast(Queued(runId: result, deckFile: deckFile, trnrunArgs: trnrunArgs))
  scheduler.dispatch()

proc cancel*(scheduler: Scheduler, runId: int) =
  ## Stops `runId` unless it already finished; `InputError` if unknown, `ValueError` once closed.
  if scheduler.isClosed:
    raise newException(ValueError, "The scheduler is closed")
  if runId in scheduler.running:
    scheduler.running[runId].kill(CancelReason)
  elif scheduler.removeQueued(runId):
    scheduler.database.cancel(runId, started = false, CancelReason)
  elif runId notin scheduler.database:
    raise newException(InputError, "Unknown runId: " & $runId)

proc requestShutdown*(scheduler: Scheduler, cancelRunning = false) =
  ## Rejects new runs and cancels queued ones, and running ones too with `cancelRunning`.
  if scheduler.isClosed:
    return
  if not scheduler.isShuttingDown:
    scheduler.isShuttingDown = true
    scheduler.database.interrupt(ShutdownReason, {ssQueued})
    scheduler.queue.clear()
  if cancelRunning:
    for run in scheduler.running.mvalues:
      run.kill(ShutdownReason)

proc isDone*(scheduler: Scheduler): bool {.inline.} =
  ## Whether a requested shutdown has no running run left to wait for.
  scheduler.isShuttingDown and scheduler.running.len == 0

proc close*(scheduler: Scheduler) =
  ## Joins every worker, then closes the database. Call once `isDone`.
  if scheduler.isClosed:
    return
  scheduler.isClosed = true
  scheduler.pool.shutdown()
  scheduler.database.close()

proc abandon*(scheduler: Scheduler) =
  ## Saves every unfinished run as interrupted and closes without joining workers; for exit only.
  if scheduler.isClosed:
    return
  scheduler.isShuttingDown = true # Also stops exits applied below from launching queued runs.
  scheduler.atomically:
    # Applies what already arrived first, so a run that just exited keeps its real outcome.
    for _ in 1..scheduler.inbox.peek(): # Bounded: running TRNRun may keep posting.
      let (available, message) = scheduler.inbox.tryRecv()
      if not available:
        break
      scheduler.apply(message)
    scheduler.database.interrupt(DisconnectReason, Unfinished)
  for run in scheduler.running.mvalues:
    run.process.kill() # The Job Object would kill them at exit anyway.
  scheduler.queue.clear()
  scheduler.running.clear() # Not closed: workers may still be reading their output.
  scheduler.isClosed = true
  scheduler.database.close()
