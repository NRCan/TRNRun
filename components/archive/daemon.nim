## Orchestrates the daemon lifecycle.
##
## The daemon thread owns every simulation. A reader thread forwards stdin
## request lines and workers forward runner output, all through one inbox
## channel, so simulation state needs no locks and every reply is written from
## a single thread.
##
## Simulations wait in a daemon-side queue until a worker is idle. Submitting
## never blocks.
##
## Stdin EOF means the wrapper is gone: queued simulations are dropped and the
## daemon exits once running ones finish. A `shutdown` request instead drains
## the queue and is answered just before exit.

when not defined(windows):
  {.error: "daemon.nim is Windows-only.".}

import std/[deques, json, tables]

import ./input
import ./job
import ./messages
import ./reply
import ./request
import ./simulation
import ./validate
import ./workerpool


type
  Waiter = object
    ## A `wait` request answered once its simulations finish.
    id: JsonNode
    upTo: int ## Wait-all only: simulations submitted before the request.

  Daemon = object
    ## Owned by the serving thread. Its address must remain stable while
    ## threads are running because they receive `ptr Channel[Message]`.
    inbox: Channel[Message]
    pool: WorkerPool
    reader: Thread[ptr Channel[Message]]
    simulations: seq[Simulation]
    index: Table[string, int]
    queue: Deque[int]
    settled: int ## Every simulation before this index has finished.
    version: int ## Bumped on every simulation change; see `touch`.
    simulationWaiters: Table[int, seq[Waiter]]
    allWaiters: seq[Waiter]
    shutdownIds: seq[JsonNode]
    closing: bool
    inputClosed: bool


# Views

proc view(daemon: Daemon, index: int): JsonNode =
  %*{"runId": daemon.simulations[index].runId, "state": daemon.simulations[index].state}


proc viewAll(daemon: Daemon, upTo: int, since = 0): JsonNode =
  ## Renders the first `upTo` simulations changed after `since`, with the
  ## current version to pass as `since` next time.
  var simulations = newJArray()
  for index in 0 ..< upTo:
    if daemon.simulations[index].version > since:
      simulations.add(daemon.view(index))

  result = %*{"version": daemon.version, "simulations": simulations}


proc lookup(daemon: Daemon, runId: string): int =
  result = daemon.index.getOrDefault(runId, -1)
  if result < 0:
    raise newException(ValueError, "Unknown runId: " & runId)


# Simulation transitions

proc touch(daemon: var Daemon, index: int) =
  ## Records that simulation `index` changed, so `list` with `since` never
  ## misses one.
  inc daemon.version
  daemon.simulations[index].version = daemon.version


proc settle(daemon: var Daemon, index: int) =
  ## Answers every `wait` satisfied by simulation `index` finishing.
  var waiters: seq[Waiter] = @[]
  if daemon.simulationWaiters.pop(index, waiters):
    for waiter in waiters:
      writeReply(okReply(waiter.id, daemon.view(index)))

  while daemon.settled < daemon.simulations.len and
      daemon.simulations[daemon.settled].state == ssFinished:
    inc daemon.settled

  var remaining: seq[Waiter] = @[]
  for waiter in daemon.allWaiters:
    if waiter.upTo <= daemon.settled:
      writeReply(okReply(waiter.id, daemon.viewAll(waiter.upTo)))
    else:
      remaining.add(waiter)
  daemon.allWaiters = remaining


proc dispatchQueued(daemon: var Daemon) =
  ## Hands queued simulations to idle workers.
  while daemon.pool.hasIdle() and daemon.queue.len > 0:
    let index = daemon.queue.popFirst()
    daemon.simulations[index].worker = daemon.pool.dispatch(Work(
      kind: wkRun,
      simulation: index,
      runId: daemon.simulations[index].runId,
      deckFile: daemon.simulations[index].deckFile,
      runnerPath: daemon.simulations[index].runnerPath,
      runnerArgs: daemon.simulations[index].runnerArgs,
    ))
    daemon.simulations[index].state = ssAccepted
    daemon.touch(index)


proc isDrained(daemon: Daemon): bool =
  ## Returns whether shutdown was requested and nothing is left to run.
  daemon.closing and daemon.queue.len == 0 and daemon.pool.isIdle()


# Commands

proc submit(daemon: var Daemon, id: JsonNode, command: Command) =
  if daemon.closing:
    raise newException(ValueError, "Daemon is shutting down")
  if command.runId in daemon.index:
    raise newException(ValueError, "Duplicate runId: " & command.runId)

  let
    deckFile = validateDeck(command.deckFile)
    runnerPath = validateTrnrun(command.runnerPath)
    index = daemon.simulations.len
  daemon.simulations.add(initSimulation(
    command.runId,
    deckFile,
    runnerPath,
    command.runnerArgs,
  ))
  daemon.index[command.runId] = index
  daemon.touch(index)
  daemon.queue.addLast(index)
  daemon.dispatchQueued()

  writeReply(okReply(id, daemon.view(index)))


proc wait(daemon: var Daemon, id: JsonNode, command: Command) =
  if command.runId.len == 0:
    let upTo = daemon.simulations.len
    if daemon.settled >= upTo:
      writeReply(okReply(id, daemon.viewAll(upTo)))
    else:
      daemon.allWaiters.add(Waiter(id: id, upTo: upTo))
  else:
    let index = daemon.lookup(command.runId)
    if daemon.simulations[index].state == ssFinished:
      writeReply(okReply(id, daemon.view(index)))
    else:
      daemon.simulationWaiters.mgetOrPut(index, @[]).add(Waiter(id: id))


proc handleCommand(daemon: var Daemon, line: string) =
  ## Executes one request. Malformed or rejected requests get an error reply;
  ## stdout failures propagate as fatal.
  var id = newJNull()
  try:
    let node = parseJson(line)
    id = requestId(node)
    let command = parseCommand(node)

    case command.kind
    of ckSubmit:
      daemon.submit(id, command)
    of ckSnapshot:
      writeReply(okReply(id, daemon.view(daemon.lookup(command.runId))))
    of ckList:
      writeReply(okReply(id, daemon.viewAll(daemon.simulations.len, command.since)))
    of ckWait:
      daemon.wait(id, command)
    of ckShutdown:
      daemon.shutdownIds.add(id)
      daemon.closing = true
  except ValueError:
    writeReply(errorReply(id, getCurrentExceptionMsg()))


proc handle(daemon: var Daemon, message: Message) =
  case message.kind
  of mkCommand:
    daemon.handleCommand(message.line)
  of mkInputClosed:
    daemon.inputClosed = true
    daemon.closing = true
    daemon.queue.clear()
  of mkLaunched:
    daemon.simulations[message.simulation].state = ssRunning
    daemon.touch(message.simulation)
  of mkOutput:
    daemon.simulations[message.simulation].applyLine(message.line)
    daemon.touch(message.simulation)
  of mkExited:
    daemon.simulations[message.simulation].finish(message.exitCode, message.error)
    daemon.touch(message.simulation)
    daemon.pool.release(message.worker)
    daemon.dispatchQueued()
    daemon.settle(message.simulation)


proc serve*(maxConcurrent: int) =
  ## Answers requests until shutdown or stdin EOF, then waits for every worker.
  if maxConcurrent < 1:
    raise newException(ValueError, "maxConcurrent must be at least 1")

  initJobGuard()

  var daemon = default(Daemon)
  daemon.inbox.open()
  daemon.pool.start(maxConcurrent, addr daemon.inbox)

  try:
    {.push warning[ProveInit]: off, warning[Uninit]: off.}
    createThread(daemon.reader, readInput, addr daemon.inbox)
    {.pop.}

    while not daemon.isDrained():
      daemon.handle(daemon.inbox.recv())

    for id in daemon.shutdownIds:
      writeReply(okReply(id, newJObject()))
  finally:
    daemon.pool.shutdown()

    # After a `shutdown` request the reader may still block on stdin; process
    # exit ends it (see `input`).
    if daemon.inputClosed:
      joinThread(daemon.reader)
