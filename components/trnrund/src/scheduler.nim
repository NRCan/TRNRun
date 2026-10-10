## Schedules simulations and owns their daemon-side state.
##
## The daemon runs one scheduler at a time. Every public operation runs on the
## owner thread. Workers only post messages, which are applied while the owner
## waits in `nextRequest`, `add`, or `shutdown`; a finished run frees its slot for the
## next queued run at that point. Always call shutdown before dropping the
## scheduler so every worker is joined, or abandon right before the process
## exits. The inbox remains open because of the Nim 2.2 ORC channel-close
## issue.
##
## Every change to a simulation is saved to the database as it is applied, so
## clients reading it see each run's progress without asking the daemon. The
## database is the record of every run: the scheduler holds a `Simulation` only
## while it is queued or a worker has it, so its memory does not grow with the
## number of finished runs.

import std/[deques, json, options, sequtils, strutils, tables]
import ./database
import ./events
import ./job
import ./messages
import ./simulation
import ./validate
import ./workerpool

export simulation

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
    running: Table[string, Simulation]
      ## Dispatched runs until their exit is applied; at most `maxConcurrent`.
    queue: Deque[Simulation]
      ## Runs waiting for a worker; their saved row is still the initial one.
    deferred: Deque[Message]
      ## Client messages that arrived while `add` waited; `nextRequest` returns them first.

proc save(self: Scheduler, runId: string, logs: openArray[LogEvent] = []) =
  ## Saves the current state of a running `runId`, with any new log entries.
  self.database.save(self.running[runId], logs)

proc dispatch(self: Scheduler) =
  ## Hands queued runs to the pool while a worker is free.
  while self.queue.len > 0 and self.running.len < self.maxConcurrent:
    var simulation = self.queue.popFirst()
    simulation.state = ssAccepted
    self.database.save(simulation)
    self.running[simulation.runId] = simulation
    self.pool.submit(Work(
      kind: wkRun,
      runId: simulation.runId,
      deckFile: simulation.deckFile,
      trnrunArgs: simulation.trnrunArgs,
    ))

proc apply(self: Scheduler, message: Message) =
  ## Applies one worker message; an exit frees a worker for the next queued run.
  case message.kind
  of mkLaunched:
    self.running[message.runId].start()
    self.save(message.runId)
  of mkOutput:
    let event = self.running[message.runId].applyLine(message.line)
    if event.isSome:
      if event.get().kind == eventLog:
        self.save(message.runId, [event.get().logData])
      else:
        self.save(message.runId)
  of mkExited:
    self.running[message.runId].finish(message.exitCode, message.error)
    self.save(message.runId)
    self.running.del(message.runId)
    self.dispatch()
  of mkRequest, mkClosed:
    discard # Only nextRequest returns client messages; elsewhere they are dropped.

proc waitUntil(self: Scheduler, runId: string, target: SimulationState): SimulationState =
  ## Applies worker messages until `runId`, just added, reaches `target`; returns its state.
  ##
  ## Client requests arriving meanwhile are deferred to `nextRequest`. If the client
  ## leaves, its pending requests are dropped and the wait ends early.
  result = if runId in self.running: self.running[runId].state else: ssQueued
  while result < target:
    let message = self.inbox.recv()
    case message.kind
    of mkRequest:
      self.deferred.addLast(message)
    of mkClosed:
      self.deferred.clear()
      self.deferred.addLast(message)
      return
    of mkLaunched, mkOutput, mkExited:
      self.apply(message)
      result =
        if runId in self.running: self.running[runId].state
        elif result == ssQueued: ssQueued # Still waiting for a worker.
        else: ssFinished # Left `running`: its exit was applied.

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
    self: Scheduler, runId, deckFile: string, trnrunArgs: seq[string] = @[],
    until = ssQueued,
): SimulationState {.discardable.} =
  ## Validates and queues work, dispatching it at once if a worker is free.
  ##
  ## Returns once the run reaches at least `until`, with the state it reached;
  ## see `waitUntil`. A runId stays taken for the life of the database, across
  ## daemon restarts.
  if self.isShutDown:
    raise newException(ValueError, "Scheduler is shut down")
  if runId.len == 0 or runId in self.database:
    raise newException(ValueError, "Invalid or duplicate runId: " & runId)
  if trnrunArgs.anyIt(it.startsWith("--deckFile")):
    raise newException(ValueError, "Pass the deck as deckFile, not in trnrunArgs")

  let simulation = initSimulation(runId, validateDeck(deckFile), trnrunArgs)
  self.database.save(simulation)
  self.queue.addLast(simulation)
  self.dispatch()
  self.waitUntil(runId, until)

proc requestInbox*(self: Scheduler): ptr Channel[Message] =
  ## Inbox address for the thread that posts `mkRequest` and `mkClosed`.
  addr self.inbox

proc nextRequest*(self: Scheduler): Message =
  ## Returns the next client message, deferred ones first, applying worker messages meanwhile.
  if self.deferred.len > 0:
    return self.deferred.popFirst()
  result = self.inbox.recv()
  while result.kind notin {mkRequest, mkClosed}:
    self.apply(result)
    result = self.inbox.recv()

proc cancelQueued(self: Scheduler, reason: string) =
  ## Finishes every queued run as interrupted, without starting it.
  while self.queue.len > 0:
    var simulation = self.queue.popFirst()
    simulation.interrupt(reason)
    self.database.save(simulation)

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
  self.cancelQueued("the daemon shut down")
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
  self.cancelQueued("the client disconnected")
  for _ in 1 .. self.inbox.peek(): # Bounded: running TRNRun may keep posting.
    let (available, message) = self.inbox.tryRecv()
    if not available:
      break
    self.apply(message)
  for runId in toSeq(self.running.keys):
    self.running[runId].interrupt("the client disconnected")
    self.save(runId)
    self.running.del(runId)
  self.database.close()
