## Schedules simulations and owns their daemon-side state.
##
## The daemon runs one scheduler at a time. Every public operation runs on the
## owner thread. Workers only post messages, which are applied while the owner
## waits in `nextRequest`, `wait`, or `poll`; a finished run frees its slot for
## the next queued run at that point. Always call shutdown before dropping the
## scheduler so every worker is joined. The inbox remains open because of the
## Nim 2.2 ORC channel-close issue.

import std/[cpuinfo, deques, options, tables]
import ./events
import ./job
import ./messages
import ./simulation
import ./validate
import ./workerpool

export simulation

type
  Scheduler* = ref object
    ## Stable allocation for the channels whose addresses workers retain.
    pool: WorkerPool
    inbox: Channel[Message]
    trnrunPath: string ## Absolute, validated at creation.
    maxConcurrent: int
    runningCount: int ## Dispatched runs whose exit messages have not been processed.
    isShutDown: bool
    registry: Table[string, Simulation]
    queue: Deque[string]

let DefaultMaxConcurrent* = max(countProcessors() - 1, 1)

proc dispatch(self: Scheduler) =
  while self.queue.len > 0 and self.runningCount < self.maxConcurrent:
    let runId = self.queue.popFirst()
    template simulation: untyped = self.registry[runId]
    self.pool.submit(Work(
      kind: wkRun,
      runId: runId,
      deckFile: simulation.deckFile,
      trnrunPath: self.trnrunPath,
      trnrunArgs: simulation.trnrunArgs,
    ))
    simulation.state = ssAccepted
    inc self.runningCount

proc apply(self: Scheduler, message: Message) =
  template simulation: untyped = self.registry[message.runId]
  case message.kind
  of mkLaunched:
    simulation.state = ssRunning
  of mkOutput:
    simulation.applyLine(message.line)
  of mkExited:
    simulation.finish(message.exitCode, message.error)
    dec self.runningCount
    self.dispatch()
  of mkRequest, mkClosed:
    discard # Only nextRequest returns client messages; elsewhere they are dropped.

proc requireKnown(self: Scheduler, runId: string) =
  if runId notin self.registry:
    raise newException(KeyError, "Unknown runId: " & runId)

# Public API

proc newScheduler*(
    trnrunPath: string, maxConcurrent: int = DefaultMaxConcurrent
): Scheduler =
  ## Creates and starts a scheduler that runs every simulation with the TRNRun
  ## at `trnrunPath`. Always call shutdown before dropping it.
  if maxConcurrent < 1:
    raise newException(ValueError, "'maxConcurrent' must be at least 1")
  let trnrunPath = validateTrnrun(trnrunPath)
  initJobGuard()
  result = Scheduler(trnrunPath: trnrunPath, maxConcurrent: maxConcurrent)
  result.inbox.open()
  result.pool.start(maxConcurrent, addr result.inbox)

proc add*(self: Scheduler, runId, deckFile: string, trnrunArgs: seq[string] = @[]) =
  ## Validates and queues work, dispatching it at once if a worker is free.
  if self.isShutDown:
    raise newException(ValueError, "Scheduler is shut down")
  if runId.len == 0 or runId in self.registry:
    raise newException(ValueError, "Invalid or duplicate runId: " & runId)

  self.registry[runId] = initSimulation(runId, validateDeck(deckFile), trnrunArgs)
  self.queue.addLast(runId)
  self.dispatch()

proc `[]`*(self: Scheduler, runId: string): lent Simulation =
  ## Borrows one simulation, logs included, for immediate reading on the owner
  ## thread. Use `snapshot` or `logs` for a copy to keep. KeyError if unknown.
  self.requireKnown(runId)
  self.registry[runId]

proc snapshot*(self: Scheduler, runId: string): Simulation =
  ## Returns a copy of one simulation's current state without its logs, which
  ## only grow; read them with `logs`. KeyError if unknown.
  self.requireKnown(runId)
  template simulation: untyped = self.registry[runId]
  var logs = move simulation.logs
  result = simulation
  simulation.logs = move logs

proc logs*(self: Scheduler, runId: string): seq[LogEvent] =
  ## Returns a copy of every log entry so far. KeyError if unknown.
  self.requireKnown(runId)
  self.registry[runId].logs

proc remove*(self: Scheduler, runId: string) =
  ## Forgets a finished simulation so its memory is freed and its runId can be
  ## reused. KeyError if unknown, ValueError if it has not finished.
  self.requireKnown(runId)
  if self.registry[runId].state != ssFinished:
    raise newException(ValueError, "Simulation has not finished: " & runId)
  self.registry.del(runId)

proc isIdle(self: Scheduler): bool =
  self.queue.len == 0 and self.runningCount == 0

proc poll*(self: Scheduler, maxMessages: int = 100): int =
  ## Processes at most maxMessages available notifications without waiting.
  ## A bound keeps TRNRun output from starving the daemon's other operations.
  result = 0
  while result < maxMessages:
    let (available, message) = self.inbox.tryRecv()
    if not available:
      break
    self.apply(message)
    inc result

proc requestInbox*(self: Scheduler): ptr Channel[Message] =
  ## Inbox address for the thread that posts `mkRequest` and `mkClosed`.
  addr self.inbox

proc nextRequest*(self: Scheduler): Message =
  ## Applies worker messages as they arrive until a client message does, then
  ## returns it. Blocks the owner thread.
  result = self.inbox.recv()
  while result.kind notin {mkRequest, mkClosed}:
    self.apply(result)
    result = self.inbox.recv()

proc wait*(self: Scheduler, runId: string = "") =
  ## Pumps messages until one simulation finishes, or all work if runId is empty.
  ## Blocks the owner thread and drops client messages that arrive meanwhile.
  if runId.len == 0:
    while not self.isIdle():
      self.apply(self.inbox.recv())
  else:
    self.requireKnown(runId)
    while self.registry[runId].state != ssFinished:
      self.apply(self.inbox.recv())

proc shutdown*(self: Scheduler) =
  ## Rejects new work and finishes queued runs as CANCELLED without starting
  ## them. Then waits for the running ones and joins the pool. Idempotent. It
  ## can wait indefinitely for TRNRun; running work cannot be cancelled.
  self.isShutDown = true
  while self.queue.len > 0:
    let runId = self.queue.popFirst()
    template simulation: untyped = self.registry[runId]
    simulation.status = some(StatusEvent(status: statusCancelled, message: "Not started"))
    simulation.finish(none(int), "Not started: the daemon shut down")
  self.wait()
  self.pool.shutdown()

# Direct-run example
when isMainModule:
  import std/[options, os, strformat]

  let
    deckDirectory = currentSourcePath().parentDir / ".." / "examples" / "dck"
    trnrunPath =
      currentSourcePath().parentDir / ".." / ".." / "trnrun" / "build" / "trnrun.exe"
    trnrunArgs = @["--guiVisibility:minAuto", "--watchTmp:true"]
    deckNames = [
      "example_w_plot_w_tracking",
      "example_w_plot_wo_tracking",
      "example_wo_plot_w_tracking",
      "example_wo_plot_wo_tracking",
    ]

  # Two slots for four decks, so the last two wait in the queue.
  let scheduler = newScheduler(trnrunPath, maxConcurrent = 2)
  try:
    for name in deckNames:
      scheduler.add(name, deckDirectory / (name & ".dck"), trnrunArgs)

    # Runs start in submission order, so a refresh can skip runs already seen
    # finished and stop at the first queued one.
    var finished = newSeq[bool](deckNames.len)
    while false in finished:
      discard scheduler.poll()
      for index, name in deckNames:
        if finished[index]:
          continue
        let simulation = scheduler.snapshot(name)
        if simulation.state == ssQueued:
          break
        finished[index] = simulation.state == ssFinished
        let percent =
          if simulation.progress.isSome: simulation.progress.get().percent * 100
          else: 0.0
        echo &"{simulation.runId:<28} {$simulation.state:<9} {percent:5.1f} %"
      echo ""
      sleep(1000)
  finally:
    scheduler.shutdown()

  for name in deckNames:
    let simulation = scheduler.snapshot(name)
    echo &"{simulation.runId}: {simulation.status.get().status}, ",
      &"exitCode: {simulation.exitCode}, error: '{simulation.error}'"
