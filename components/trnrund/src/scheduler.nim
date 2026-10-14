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
## or `abandon` it right before the process exits. The inbox remains open
## because of the Nim 2.2 ORC channel-close issue.
##
## The database is the record of every run; the scheduler only keeps in memory
## the runs waiting for a slot and those running, which a new daemon never
## resumes anyway.

import std/[deques, options, osproc, tables]
import ./database
import ./events
import ./job
import ./messages
import ./trnrun
import ./validate
import ./workerpool

export InputError

const
  CancelReason = "cancelled by the client"
  ShutdownReason = "the daemon shut down"
  DisconnectReason = "the client disconnected"
  MaxBatch = 1_000 ## Most messages `receive` returns at once, bounding a batch's transaction.

type
  Queued = object
    runId: int
    deckFile: string
    trnrunArgs: seq[string]

  Running = object
    ## A launched run, until its exit is applied.
    process: Process
    cancelReason: string ## Why it was killed; empty unless cancelled.

  Scheduler* = ref object
    ## Queued and running simulations, plus the pool that reads their output.
    ##
    ## A `ref` so the inbox and work channel keep the stable addresses that
    ## the workers and the request reader retain.
    pool: WorkerPool
    inbox: Channel[Message]
    database: Database

    trnrunPath: string
    maxConcurrent: int
    isShuttingDown: bool ## No more runs start; set by `requestShutdown` and `abandon`.
    isClosed: bool ## The database is closed; set by `close` and `abandon`.
    queue: Deque[Queued]
      ## Submitted runs waiting for a slot, oldest first.
    running: Table[int, Running]
      ## Launched runs until their exit is applied; at most `maxConcurrent`.

proc dispatch(scheduler: Scheduler) =
  ## Launches the longest-queued runs while a slot is free.
  ##
  ## A run whose TRNRun cannot start finishes at once with the launch error.
  while not scheduler.isShuttingDown and scheduler.running.len < scheduler.maxConcurrent and
      scheduler.queue.len > 0:
    let run = scheduler.queue.popFirst()
    let launched =
      try:
        launch(run.runId, run.deckFile, scheduler.trnrunPath, run.trnrunArgs)
      except CatchableError as error:
        scheduler.database.finish(run.runId, none(int), error.msg)
        continue
    scheduler.database.start(run.runId)
    scheduler.running[run.runId] = Running(process: launched.process)
    scheduler.pool.submit(
      Work(kind: wkRead, runId: run.runId, output: launched.output, process: launched.waitHandle)
    )

proc kill(run: var Running, reason: string) =
  ## Kills a running TRNRun once; its exit is applied as cancelled for `reason`.
  ## A TRNRun that already exited, before its exit is applied, keeps its real outcome.
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
  ## Starts a scheduler that runs the TRNRun at `trnrunPath` and saves to
  ## `databasePath`, in a new session. Raises `InputError` on bad input,
  ## `DbError` if the database cannot be opened.
  if maxConcurrent < 1:
    raise newException(InputError, "'maxConcurrent' must be at least 1")
  let trnrunPath = validateFile(trnrunPath, "TRNRun")
  initJobGuard()
  result = Scheduler(
    trnrunPath: trnrunPath, maxConcurrent: maxConcurrent, database: openDatabase(databasePath)
  )
  result.inbox.open()
  result.pool.start(maxConcurrent, addr result.inbox)

proc database*(scheduler: Scheduler): Database =
  ## The database every change is saved to.
  scheduler.database

proc databasePath*(scheduler: Scheduler): string =
  ## Absolute path of the database clients read.
  scheduler.database.path

template atomically*(scheduler: Scheduler, body: untyped) =
  ## Applies `body` in one database transaction; readers see its changes at once.
  scheduler.database.transaction:
    body

proc add*(
    scheduler: Scheduler, deckFile: string, trnrunArgs: seq[string] = @[], label = none(string)
): int =
  ## Validates and queues a run, launching it at once if a slot is free;
  ## returns the `run_id` the database assigned it.
  ##
  ## Raises `InputError` for invalid input or once shutting down.
  if scheduler.isShuttingDown:
    raise newException(InputError, "The daemon is shutting down")
  validateTrnrunArgs(trnrunArgs)
  let deckFile = validateDeck(deckFile)
  result = scheduler.database.submit(deckFile, trnrunArgs, label)
  scheduler.queue.addLast(Queued(runId: result, deckFile: deckFile, trnrunArgs: trnrunArgs))
  scheduler.dispatch()

proc cancel*(scheduler: Scheduler, runId: int) =
  ## Stops `runId` unless it already finished, which leaves it unchanged.
  ##
  ## A queued run finishes as CANCELLED at once. A running one is killed and
  ## finishes as CANCELLED when its exit is applied. Allowed while shutting
  ## down. Raises `InputError` for an unknown runId, and `ValueError` once
  ## closed.
  if scheduler.isClosed:
    raise newException(ValueError, "The scheduler is closed")
  if runId in scheduler.running:
    scheduler.running[runId].kill(CancelReason)
  elif scheduler.removeQueued(runId):
    scheduler.database.cancel(runId, started = false, CancelReason)
  elif runId notin scheduler.database:
    raise newException(InputError, "Unknown runId: " & $runId)

proc apply*(scheduler: Scheduler, message: Message) =
  ## Applies one worker message; an exit frees a slot for the next queued run.
  ## Client messages are ignored.
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

proc requestInbox*(scheduler: Scheduler): ptr Channel[Message] =
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

proc requestShutdown*(scheduler: Scheduler, cancelRunning = false) =
  ## Rejects new runs and finishes queued ones as CANCELLED, without waiting.
  ##
  ## With `cancelRunning`, running runs are killed too. Repeating it is
  ## harmless and can add `cancelRunning`. The scheduler `isDone` once no run
  ## is running.
  if scheduler.isClosed:
    return
  if not scheduler.isShuttingDown:
    scheduler.isShuttingDown = true
    scheduler.database.interrupt(ShutdownReason, {ssQueued})
    scheduler.queue.clear()
  if cancelRunning:
    for run in scheduler.running.mvalues:
      run.kill(ShutdownReason)

proc isDone*(scheduler: Scheduler): bool =
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
  ## Finishes every queued and running run as interrupted, kills running
  ## TRNRun, then closes the database without joining the workers. For a
  ## daemon about to exit.
  ##
  ## Worker messages that already arrived are applied first, so a run that
  ## exited just before keeps its real outcome. Idempotent, and a no-op after
  ## `close`.
  if scheduler.isClosed:
    return
  scheduler.isShuttingDown = true # Also stops exits applied below from launching queued runs.
  scheduler.atomically:
    for _ in 1 .. scheduler.inbox.peek(): # Bounded: running TRNRun may keep posting.
      let (available, message) = scheduler.inbox.tryRecv()
      if not available:
        break
      scheduler.apply(message)
    scheduler.database.interrupt(DisconnectReason, Unfinished)
  for run in scheduler.running.mvalues:
    run.process.kill() # The job object would kill them at exit anyway.
  scheduler.queue.clear()
  scheduler.running.clear() # Not closed: workers may still be reading their output.
  scheduler.isClosed = true
  scheduler.database.close()
