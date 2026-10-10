## Schedules simulations and saves their state to the database.
##
## The daemon runs one scheduler at a time. Every public operation runs on the
## owner thread. Workers only post messages, which are applied while the owner
## waits in `nextRequest` or `shutdown`; a finished run frees its slot for the
## next queued run at that point. Always call shutdown before dropping the
## scheduler so every worker is joined, or abandon right before the process
## exits. The inbox remains open because of the Nim 2.2 ORC channel-close
## issue.
##
## Every change to a simulation is saved to the database as it is applied, so
## clients reading it see each run's progress without asking the daemon. The
## database is the record of every run: the scheduler only remembers which
## runs wait for a worker and which a worker has, so its memory does not grow
## with the number of finished runs.

import std/[deques, options, sequtils, sets, strutils]
import ./database
import ./events
import ./job
import ./messages
import ./validate
import ./workerpool

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
    running: HashSet[string]
      ## Dispatched runs until their exit is applied; at most `maxConcurrent`.
    queue: Deque[Work]
      ## Runs waiting for a worker; still `QUEUED` in the database.

proc dispatch(self: Scheduler) =
  ## Hands queued runs to the pool while a worker is free.
  while self.queue.len > 0 and self.running.len < self.maxConcurrent:
    let work = self.queue.popFirst()
    self.database.accept(work.runId)
    self.running.incl(work.runId)
    self.pool.submit(work)

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
    self.database.finish(message.runId, message.exitCode, message.error)
    self.running.excl(message.runId)
    self.dispatch()
  of mkRequest, mkClosed:
    discard # Only nextRequest returns client messages; elsewhere they are dropped.

# Public API

proc newScheduler*(
    trnrunPath: string, maxConcurrent: int, databasePath: string
): Scheduler =
  ## Starts a scheduler that runs the TRNRun at `trnrunPath` and saves to
  ## `databasePath`. Raises `ValueError` on bad input, `DatabaseError` if the
  ## database cannot be opened.
  if maxConcurrent < 1:
    raise newException(ValueError, "'maxConcurrent' must be at least 1")
  let trnrunPath = validateTrnrun(trnrunPath)
  initJobGuard()
  result = Scheduler(maxConcurrent: maxConcurrent, database: openDatabase(databasePath))
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
  if trnrunArgs.anyIt(it.startsWith("--deckFile")):
    raise newException(ValueError, "Pass the deck as deckFile, not in trnrunArgs")

  let deckFile = validateDeck(deckFile)
  self.database.submit(runId, deckFile)
  self.queue.addLast(Work(kind: wkRun, runId: runId, deckFile: deckFile, trnrunArgs: trnrunArgs))
  self.dispatch()
  if runId in self.running: ssAccepted else: ssQueued

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
  ## after `abandon`. It can wait indefinitely for TRNRun, since running work
  ## cannot be cancelled.
  if self.isShutDown:
    return
  self.isShutDown = true
  self.queue.clear()
  self.database.interrupt("the daemon shut down", {ssQueued})
  while self.running.len > 0:
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
  self.isShutDown = true
  self.queue.clear()
  for _ in 1 .. self.inbox.peek(): # Bounded: running TRNRun may keep posting.
    let (available, message) = self.inbox.tryRecv()
    if not available:
      break
    self.apply(message)
  self.database.interrupt("the client disconnected")
  self.running.clear()
  self.database.close()
