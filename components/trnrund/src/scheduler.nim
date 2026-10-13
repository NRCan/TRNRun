## Schedules simulations and saves their state to the database.
##
## The daemon runs one scheduler at a time. Every public operation runs on the
## owner thread. Workers only post messages, which are applied while the owner
## waits in `nextRequest` or `shutdown`; a finished run frees its slot for the
## next queued run at that point. To cancel a dispatched run, the owner sets a
## flag the run's worker polls. Always call shutdown before dropping the
## scheduler so every worker is joined, or abandon right before the process
## exits. The inbox remains open because of the Nim 2.2 ORC channel-close
## issue.
##
## Every change to a simulation is saved to the database as it is applied, so
## clients reading it see each run's progress without asking the daemon. The
## database is the record of every run; the scheduler only keeps in memory the
## runs waiting for a worker and those a worker has, which a new daemon never
## resumes anyway.

import std/[atomics, deques, options, tables]
import ./database
import ./events
import ./job
import ./messages
import ./validate
import ./workerpool

const CancelReason = "cancelled by the client"

type
  Scheduler* = ref object
    ## Queued and dispatched simulations, plus the pool that runs them.
    ##
    ## A `ref` so the inbox and work channel keep the stable addresses that
    ## the workers and the request reader retain.
    pool: WorkerPool
    inbox: Channel[Message]
    database: Database

    maxConcurrent: int
    isShutDown: bool
    queue: Deque[Work]
      ## Submitted runs waiting for a worker, oldest first.
    dispatched: Table[string, ptr Atomic[bool]]
      ## Cancel flag of each dispatched run until its exit is applied; at most
      ## `maxConcurrent` runs.

proc running(self: Scheduler): int =
  ## Dispatched runs whose exit is not applied yet.
  self.dispatched.len

proc dispatch(self: Scheduler) =
  ## Hands the longest-queued runs to the pool while a worker is free.
  while not self.isShutDown and self.running < self.maxConcurrent and self.queue.len > 0:
    var work = self.queue.popFirst()
    work.cancel = createShared(Atomic[bool])
    self.dispatched[work.runId] = work.cancel
    self.database.accept(work.runId)
    self.pool.submit(work)

proc finishExited(self: Scheduler, message: Message) =
  ## Saves the outcome of a worker's run, then frees its cancel flag and worker.
  if message.cancelled:
    self.database.cancel(message.runId, started = message.exitCode.isSome, CancelReason)
  else:
    self.database.finish(message.runId, message.exitCode, message.error)
  var cancel: ptr Atomic[bool] = nil
  if self.dispatched.pop(message.runId, cancel):
    freeShared(cancel)

proc apply(self: Scheduler, message: Message) =
  ## Applies one worker message; an exit frees a worker for the next queued run.
  case message.kind
  of mkLaunched:
    self.database.start(message.runId)
  of mkOutput:
    let event = parseEventLine(message.line)
    if event.isSome:
      self.database.record(message.runId, event.get())
  of mkExited:
    self.finishExited(message)
    self.dispatch()
  of mkRequest, mkClosed:
    discard # Only nextRequest returns client messages; elsewhere they are dropped.

proc removeQueued(self: Scheduler, runId: string): bool =
  ## Removes `runId` from the queue, keeping the others in order; whether it was there.
  var kept = initDeque[Work]()
  for work in self.queue:
    if work.runId != runId:
      kept.addLast(work)
  result = kept.len < self.queue.len
  self.queue = kept

# Public API

proc newScheduler*(
    trnrunPath: string, maxConcurrent: int, databasePath: string, overwrite = false
): Scheduler =
  ## Starts a scheduler that runs the TRNRun at `trnrunPath` and saves to
  ## `databasePath`. Raises `ValueError` on bad input, `DbError` if the
  ## database cannot be opened.
  if maxConcurrent < 1:
    raise newException(ValueError, "'maxConcurrent' must be at least 1")
  let trnrunPath = validateFile(trnrunPath, "TRNRun")
  initJobGuard()
  result = Scheduler(maxConcurrent: maxConcurrent, database: openDatabase(databasePath, overwrite))
  result.inbox.open()
  result.pool.start(trnrunPath, maxConcurrent, addr result.inbox)

proc databasePath*(self: Scheduler): string =
  ## Absolute path of the database clients read.
  self.database.path

proc add*(
    self: Scheduler, runId, deckFile: string, trnrunArgs: seq[string] = @[]
): SimulationState {.discardable.} =
  ## Validates and queues work, dispatching it at once if a worker is free.
  ##
  ## Returns `ACCEPTED` if a worker took it, else `QUEUED`. A runId stays
  ## taken for the life of the database, across daemon restarts.
  if self.isShutDown:
    raise newException(ValueError, "Scheduler is shut down")
  if runId.len == 0 or runId in self.database:
    raise newException(ValueError, "Invalid or duplicate runId: " & runId)
  validateTrnrunArgs(trnrunArgs)

  let deckFile = validateDeck(deckFile)
  self.database.submit(runId, deckFile, trnrunArgs)
  self.queue.addLast(Work(kind: wkRun, runId: runId, deckFile: deckFile, trnrunArgs: trnrunArgs))
  self.dispatch()
  if self.queue.len == 0: ssAccepted else: ssQueued # The new run is last, so it left the queue only if all did.

proc cancel*(self: Scheduler, runId: string) =
  ## Stops `runId` unless it already finished, which leaves it unchanged.
  ##
  ## A queued run finishes as CANCELLED at once. A dispatched one is flagged:
  ## its worker kills TRNRun, or skips the launch, and the run finishes as
  ## CANCELLED when its exit is applied. Raises `ValueError` for an unknown
  ## runId or once shut down.
  if self.isShutDown:
    raise newException(ValueError, "Scheduler is shut down")
  if runId in self.dispatched:
    self.dispatched[runId][].store(true)
  elif self.removeQueued(runId):
    self.database.cancel(runId, started = false, CancelReason)
  elif runId notin self.database:
    raise newException(ValueError, "Unknown runId: " & runId)

proc requestInbox*(self: Scheduler): ptr Channel[Message] =
  ## Inbox address for the thread that posts `mkRequest` and `mkClosed`.
  addr self.inbox

proc nextRequest*(self: Scheduler): Message =
  ## Returns the next client message, applying worker messages meanwhile.
  result = self.inbox.recv()
  while result.kind notin {mkRequest, mkClosed}:
    self.apply(result)
    result = self.inbox.recv()

proc shutdown*(self: Scheduler) =
  ## Rejects new work, waits for running work, joins the pool, then closes
  ## the database.
  ##
  ## Queued runs finish as CANCELLED without starting. Idempotent, and a no-op
  ## after `abandon`. It can wait indefinitely for TRNRun: running work is not
  ## cancelled, and no `cancel` can be made once shutdown starts.
  if self.isShutDown:
    return
  self.isShutDown = true
  self.database.interrupt("the daemon shut down", {ssQueued})
  self.queue.clear()
  while self.running > 0:
    self.apply(self.inbox.recv()) # Drops client messages that arrive meanwhile.
  self.pool.shutdown()
  self.database.close()

proc abandon*(self: Scheduler) =
  ## Finishes every queued and running run as interrupted, without waiting for
  ## TRNRun, then closes the database. For a daemon about to exit, whose job
  ## object then kills TRNRun; the workers are never joined.
  ##
  ## Worker messages that already arrived are applied first, so a run that
  ## exited just before keeps its real outcome. Idempotent, and a no-op after
  ## `shutdown`.
  if self.isShutDown:
    return
  self.isShutDown = true # Also stops exits applied below from dispatching queued runs.
  for _ in 1 .. self.inbox.peek(): # Bounded: running TRNRun may keep posting.
    let (available, message) = self.inbox.tryRecv()
    if not available:
      break
    self.apply(message)
  self.database.interrupt("the client disconnected", Unfinished)
  self.queue.clear()
  self.dispatched.clear() # Not freed: workers still running TRNRun keep reading their flags.
  self.database.close()
