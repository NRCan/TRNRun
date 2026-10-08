## Schedules simulations and owns their daemon-side state.
##
## The daemon runs one scheduler at a time. Every public operation runs on the
## owner thread. Workers only post messages, which are applied while the owner
## waits in `nextRequest` or `shutdown`; a finished run frees its slot for the
## next queued run at that point. Always call shutdown before dropping the
## scheduler so every worker is joined. The inbox remains open because of the
## Nim 2.2 ORC channel-close issue.
##
## Every change to a simulation gets the next revision, a counter that only
## grows, so a client holding revision N can ask for the simulations changed
## after it.

import std/[deques, options, sequtils, strutils, tables]
import ./events
import ./job
import ./messages
import ./simulation
import ./validate
import ./workerpool

export simulation

type
  Scheduler* = ref object
    ## Daemon-side state of every simulation, plus the pool that runs them.
    ##
    ## A `ref` so the inbox and work channel keep the stable addresses that
    ## the workers and the request reader retain.
    pool: WorkerPool
    inbox: Channel[Message]

    maxConcurrent: int
    runningCount: int ## Dispatched runs whose exit messages have not been processed.
    isShutDown: bool
    lastRevision: int ## Revision of the latest change to any simulation; 0 before any.
    registry: OrderedTable[string, Simulation]
      ## In submission order. Its `del` is linear, which is fine while clients
      ## hold a bounded window of simulations.
    queue: Deque[string]

proc nextRevision(self: Scheduler): int =
  ## Returns the revision for the next change.
  inc self.lastRevision
  self.lastRevision

proc setState(self: Scheduler, runId: string, state: SimulationState) =
  ## Moves a simulation to `state` as a new revision.
  self.registry[runId].state = state
  self.registry[runId].revision = self.nextRevision()

proc dispatch(self: Scheduler) =
  ## Hands queued runs to the pool while a worker is free.
  while self.queue.len > 0 and self.runningCount < self.maxConcurrent:
    let runId = self.queue.popFirst()
    self.pool.submit(Work(
      kind: wkRun,
      runId: runId,
      deckFile: self.registry[runId].deckFile,
      trnrunArgs: self.registry[runId].trnrunArgs,
    ))
    self.setState(runId, ssAccepted)
    inc self.runningCount

proc apply(self: Scheduler, message: Message) =
  ## Applies one worker message; an exit frees a worker for the next queued run.
  case message.kind
  of mkLaunched:
    self.setState(message.runId, ssRunning)
  of mkOutput:
    self.registry[message.runId].applyLine(message.line, self.nextRevision())
  of mkExited:
    self.registry[message.runId].finish(message.exitCode, message.error)
    self.registry[message.runId].revision = self.nextRevision()
    dec self.runningCount
    self.dispatch()
  of mkRequest, mkClosed:
    discard # Only nextRequest returns client messages; elsewhere they are dropped.

# Public API

proc newScheduler*(trnrunPath: string, maxConcurrent: int): Scheduler =
  ## Starts a scheduler that runs the TRNRun at `trnrunPath`; `ValueError` on bad input.
  if maxConcurrent < 1:
    raise newException(ValueError, "'maxConcurrent' must be at least 1")
  let trnrunPath = validateTrnrun(trnrunPath)
  initJobGuard()
  result = Scheduler(maxConcurrent: maxConcurrent)
  result.inbox.open()
  result.pool.start(trnrunPath, maxConcurrent, addr result.inbox)

proc add*(self: Scheduler, runId, deckFile: string, trnrunArgs: seq[string] = @[]) =
  ## Validates and queues work, dispatching it at once if a worker is free.
  if self.isShutDown:
    raise newException(ValueError, "Scheduler is shut down")
  if runId.len == 0 or runId in self.registry:
    raise newException(ValueError, "Invalid or duplicate runId: " & runId)
  if trnrunArgs.anyIt(it.startsWith("--deckFile")):
    raise newException(ValueError, "Pass the deck as deckFile, not in trnrunArgs")

  self.registry[runId] = initSimulation(runId, validateDeck(deckFile), trnrunArgs)
  self.registry[runId].revision = self.nextRevision()
  self.queue.addLast(runId)
  self.dispatch()

proc `[]`*(self: Scheduler, runId: string): lent Simulation =
  ## Borrows one simulation for immediate reading; `KeyError` if unknown.
  if runId notin self.registry:
    raise newException(KeyError, "Unknown runId: " & runId)
  self.registry[runId]

iterator items*(self: Scheduler): lent Simulation =
  ## Borrows every simulation in submission order; a re-added runId goes last.
  for simulation in self.registry.values:
    yield simulation

proc remove*(self: Scheduler, runId: string) =
  ## Forgets a finished simulation, freeing its runId. Raises if unknown or unfinished.
  if self[runId].state != ssFinished:
    raise newException(ValueError, "Simulation has not finished: " & runId)
  self.registry.del(runId)

proc revision*(self: Scheduler): int =
  ## Revision of the latest change to any simulation; 0 before the first.
  self.lastRevision

proc requestInbox*(self: Scheduler): ptr Channel[Message] =
  ## Inbox address for the thread that posts `mkRequest` and `mkClosed`.
  addr self.inbox

proc nextRequest*(self: Scheduler): Message =
  ## Applies worker messages until a client message arrives, then returns it.
  result = self.inbox.recv()
  while result.kind notin {mkRequest, mkClosed}:
    self.apply(result)
    result = self.inbox.recv()

proc shutdown*(self: Scheduler) =
  ## Rejects new work, waits for running work, then joins the pool.
  ##
  ## Queued runs finish as CANCELLED without starting. Idempotent. It can wait
  ## indefinitely for TRNRun, since running work cannot be cancelled.
  self.isShutDown = true
  while self.queue.len > 0:
    let runId = self.queue.popFirst()
    self.registry[runId].status =
      some(StatusEvent(status: statusCancelled, message: "Not started"))
    self.registry[runId].finish(none(int), "Not started: the daemon shut down")
    self.registry[runId].revision = self.nextRevision()
  while self.runningCount > 0:
    self.apply(self.inbox.recv()) # Drops client messages that arrive meanwhile.
  self.pool.shutdown()
