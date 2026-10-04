## Runs dispatched work on a fixed pool of worker threads.
##
## Each worker owns one child at a time and has its own work channel, so the
## daemon always knows which worker runs which simulation. Dispatching never blocks:
## the daemon only hands work to a worker it knows is idle, and a worker becomes
## idle again once the daemon processes its `mkExited` message.
##
## Pools are single-use because their channels remain open to avoid a Nim 2.2
## ORC crash when closing channels that transported moved strings.

import ./messages
import ./runner


type
  WorkerSlot = object
    work: Channel[Work]

  WorkerContext = object
    index: int
    slot: ptr WorkerSlot
    inbox: ptr Channel[Message]

  PoolState = enum
    psNew
    psRunning
    psStopped

  WorkerPool* = object
    ## Owned by the daemon thread. Its slots must remain at stable addresses
    ## while workers are running because each worker receives `ptr WorkerSlot`.
    slots: seq[WorkerSlot]
    threads: seq[Thread[WorkerContext]]
    idle: seq[int]
    state: PoolState


proc runWorker(context: WorkerContext) {.thread.} =
  ## Runs work from this worker's channel until a stop item arrives.
  while true:
    let work = context.slot[].work.recv()

    case work.kind
    of wkStop:
      break

    of wkRun:
      runTrnrun(work, context.index, context.inbox[])


proc stopWorkers(pool: var WorkerPool) =
  ## Stops every worker and joins its thread. Busy workers finish first.
  for index in 0 ..< pool.threads.len:
    pool.slots[index].work.send(Work(kind: wkStop))

  for index in 0 ..< pool.threads.len:
    joinThread(pool.threads[index])

  pool.threads.setLen(0)


proc start*(pool: var WorkerPool, maxConcurrent: int, inbox: ptr Channel[Message]) =
  ## Starts `maxConcurrent` idle workers that report to `inbox`.
  if maxConcurrent < 1:
    raise newException(ValueError, "maxConcurrent must be at least 1")

  if pool.state != psNew:
    raise newException(ValueError, "worker pool is single-use")

  # A failed startup also consumes the single-use pool.
  pool.state = psStopped

  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  pool.slots = newSeq[WorkerSlot](maxConcurrent)
  pool.threads = newSeq[Thread[WorkerContext]](maxConcurrent)

  for index in 0 ..< maxConcurrent:
    pool.slots[index].work.open()

  try:
    for index in 0 ..< maxConcurrent:
      let context = WorkerContext(
        index: index,
        slot: addr pool.slots[index],
        inbox: inbox,
      )
      try:
        createThread(pool.threads[index], runWorker, context)
      except CatchableError:
        pool.threads.setLen(index)
        raise
      pool.idle.add(index)
  except CatchableError:
    stopWorkers(pool)
    pool.idle.setLen(0)
    raise
  {.pop.}

  pool.state = psRunning


proc hasIdle*(pool: WorkerPool): bool =
  ## Returns whether a worker can take work right now.
  pool.state == psRunning and pool.idle.len > 0


proc isIdle*(pool: WorkerPool): bool =
  ## Returns whether no worker is running anything.
  pool.idle.len == pool.threads.len


proc dispatch*(pool: var WorkerPool, work: Work): int =
  ## Hands `work` to an idle worker and returns that worker's index.
  if not pool.hasIdle():
    raise newException(ValueError, "no idle worker")

  result = pool.idle.pop()
  pool.slots[result].work.send(work)


proc release*(pool: var WorkerPool, worker: int) =
  ## Marks `worker` idle after the daemon processed its `mkExited` message.
  pool.idle.add(worker)


proc shutdown*(pool: var WorkerPool) =
  ## Stops and joins every worker. Busy workers finish their simulation first.
  ##
  ## Safe before `start` and after an earlier shutdown. Channels deliberately
  ## remain open because closing them triggers a Nim 2.2 ORC failure.
  if pool.state != psRunning:
    return

  pool.state = psStopped

  stopWorkers(pool)
