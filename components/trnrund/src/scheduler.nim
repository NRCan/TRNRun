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
## Close the scheduler with `close` once `isDone`, or with `shutdown`, so every
## worker is joined, or `abandon` it right before the process exits. The inbox
## remains open because of the Nim 2.2 ORC channel-close issue.
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

const
  CancelReason = "cancelled by the client"
  ShutdownReason = "the daemon shut down"
  DisconnectReason = "the client disconnected"
  MaxBatch = 1_000 ## Most messages `receive` returns at once, bounding a batch's transaction.

type
  Queued = object
    ## A submitted run waiting for a slot.
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

proc dispatch(self: Scheduler) =
  ## Launches the longest-queued runs while a slot is free.
  ##
  ## A run whose TRNRun cannot start finishes at once with the launch error.
  while not self.isShuttingDown and self.running.len < self.maxConcurrent and self.queue.len > 0:
    let run = self.queue.popFirst()
    var launched = default(Launched)
    try:
      launched = launch(run.runId, run.deckFile, self.trnrunPath, run.trnrunArgs)
    except CatchableError as error:
      self.database.finish(run.runId, none(int), error.msg)
      continue
    self.database.start(run.runId)
    self.running[run.runId] = Running(process: launched.process)
    self.pool.submit(
      Work(kind: wkRead, runId: run.runId, output: launched.output, process: launched.waitHandle)
    )

proc kill(run: var Running, reason: string) =
  ## Kills a running TRNRun once; its exit is applied as cancelled for `reason`.
  if run.cancelReason.len == 0:
    run.cancelReason = reason
    run.process.kill()

proc finishExited(self: Scheduler, message: Message) =
  ## Saves the outcome of a run whose output is drained, then closes its process.
  var run = default(Running)
  if not self.running.pop(message.runId, run):
    return
  if run.cancelReason.len > 0:
    self.database.cancel(message.runId, started = true, run.cancelReason)
  else:
    self.database.finish(message.runId, message.exitCode, message.error)
  try:
    run.process.close()
  except CatchableError:
    discard # The run is saved; a handle that fails to close changes nothing for it.

proc removeQueued(self: Scheduler, runId: int): bool =
  ## Removes `runId` from the queue, keeping the others in order; whether it was there.
  var kept = initDeque[Queued]()
  for run in self.queue:
    if run.runId != runId:
      kept.addLast(run)
  result = kept.len < self.queue.len
  self.queue = kept

# Public API

proc newScheduler*(trnrunPath: string, maxConcurrent: int, databasePath: string): Scheduler =
  ## Starts a scheduler that runs the TRNRun at `trnrunPath` and saves to
  ## `databasePath`, in a new session. Raises `ValueError` on bad input,
  ## `DbError` if the database cannot be opened.
  if maxConcurrent < 1:
    raise newException(ValueError, "'maxConcurrent' must be at least 1")
  let trnrunPath = validateFile(trnrunPath, "TRNRun")
  initJobGuard()
  result = Scheduler(
    trnrunPath: trnrunPath, maxConcurrent: maxConcurrent, database: openDatabase(databasePath)
  )
  result.inbox.open()
  result.pool.start(maxConcurrent, addr result.inbox)

proc database*(self: Scheduler): Database =
  ## The database every change is saved to.
  self.database

proc databasePath*(self: Scheduler): string =
  ## Absolute path of the database clients read.
  self.database.path

template atomically*(self: Scheduler, body: untyped) =
  ## Applies `body` in one database transaction; readers see its changes at once.
  self.database.transaction:
    body

proc add*(
    self: Scheduler, deckFile: string, trnrunArgs: seq[string] = @[], label = none(string)
): int =
  ## Validates and queues a run, launching it at once if a slot is free;
  ## returns the `run_id` the database assigned it.
  ##
  ## Raises `ValueError` for invalid input or once shutting down.
  if self.isShuttingDown:
    raise newException(ValueError, "The daemon is shutting down")
  validateTrnrunArgs(trnrunArgs)
  let deckFile = validateDeck(deckFile)
  result = self.database.submit(deckFile, trnrunArgs, label)
  self.queue.addLast(Queued(runId: result, deckFile: deckFile, trnrunArgs: trnrunArgs))
  self.dispatch()

proc cancel*(self: Scheduler, runId: int) =
  ## Stops `runId` unless it already finished, which leaves it unchanged.
  ##
  ## A queued run finishes as CANCELLED at once. A running one is killed and
  ## finishes as CANCELLED when its exit is applied. Allowed while shutting
  ## down. Raises `ValueError` for an unknown runId or once closed.
  if self.isClosed:
    raise newException(ValueError, "The scheduler is closed")
  if runId in self.running:
    self.running[runId].kill(CancelReason)
  elif self.removeQueued(runId):
    self.database.cancel(runId, started = false, CancelReason)
  elif runId notin self.database:
    raise newException(ValueError, "Unknown runId: " & $runId)

proc apply*(self: Scheduler, message: Message) =
  ## Applies one worker message; an exit frees a slot for the next queued run.
  ## Client messages are ignored.
  case message.kind
  of mkOutput:
    let event = parseEventLine(message.line)
    if event.isSome:
      self.database.record(message.runId, event.get())
  of mkExited:
    self.finishExited(message)
    self.dispatch()
  of mkRequest, mkClosed:
    discard

proc requestInbox*(self: Scheduler): ptr Channel[Message] =
  ## Inbox address for the thread that posts `mkRequest` and `mkClosed`.
  addr self.inbox

proc receive*(self: Scheduler): seq[Message] =
  ## Waits for the next message, then also returns those already waiting.
  result = @[self.inbox.recv()]
  while result.len < MaxBatch:
    let (available, message) = self.inbox.tryRecv()
    if not available:
      break
    result.add(message)

proc requestShutdown*(self: Scheduler, cancelRunning = false) =
  ## Rejects new runs and finishes queued ones as CANCELLED, without waiting.
  ##
  ## With `cancelRunning`, running runs are killed too. Repeating it is
  ## harmless and can add `cancelRunning`. The scheduler `isDone` once no run
  ## is running.
  if self.isClosed:
    return
  if not self.isShuttingDown:
    self.isShuttingDown = true
    self.database.interrupt(ShutdownReason, {ssQueued})
    self.queue.clear()
  if cancelRunning:
    for run in self.running.mvalues:
      run.kill(ShutdownReason)

proc isDone*(self: Scheduler): bool =
  ## Whether a requested shutdown has no running run left to wait for.
  self.isShuttingDown and self.running.len == 0

proc close*(self: Scheduler) =
  ## Joins every worker, then closes the database. Call once `isDone`.
  if self.isClosed:
    return
  self.isClosed = true
  self.pool.shutdown()
  self.database.close()

proc shutdown*(self: Scheduler, cancelRunning = false) =
  ## Requests shutdown, applies worker messages until no run is running, then
  ## closes. Client messages that arrive meanwhile are dropped.
  ##
  ## Without `cancelRunning` it waits as long as TRNRun runs. Idempotent, and
  ## a no-op after `abandon`.
  if self.isClosed:
    return
  self.requestShutdown(cancelRunning)
  while not self.isDone:
    let messages = self.receive()
    self.atomically:
      for message in messages:
        self.apply(message)
  self.close()

proc abandon*(self: Scheduler) =
  ## Finishes every queued and running run as interrupted, kills running
  ## TRNRun, then closes the database without joining the workers. For a
  ## daemon about to exit.
  ##
  ## Worker messages that already arrived are applied first, so a run that
  ## exited just before keeps its real outcome. Idempotent, and a no-op after
  ## `close`.
  if self.isClosed:
    return
  self.isShuttingDown = true # Also stops exits applied below from launching queued runs.
  self.atomically:
    for _ in 1 .. self.inbox.peek(): # Bounded: running TRNRun may keep posting.
      let (available, message) = self.inbox.tryRecv()
      if not available:
        break
      self.apply(message)
    self.database.interrupt(DisconnectReason, Unfinished)
  for run in self.running.mvalues:
    run.process.kill() # The job object would kill them at exit anyway.
  self.queue.clear()
  self.running.clear() # Not closed: workers may still be reading their output.
  self.isClosed = true
  self.database.close()
