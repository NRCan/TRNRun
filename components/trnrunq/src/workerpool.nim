## Runs accepted requests on a fixed pool of worker threads.
##
## Each worker runs one child at a time and forwards its output through a shared,
## synchronized sink. A positive `maxPending` bounds the pending queue; zero
## leaves it unbounded. Shutdown drains accepted work before joining the workers.
##
## Pools are single-use because their channel remains open to avoid a Nim 2.2
## ORC crash when closing channels that transported moved strings.

import ./outputsink
import ./request
import ./status
import ./trnrun


type
  WorkKind = enum
    wkRun
    wkStop

  Work = object
    case kind: WorkKind
    of wkRun:
      request: RunRequest
    of wkStop:
      discard

  PoolState = enum
    psNew
    psRunning
    psStopped

  WorkerPool* = object
    ## Must not be copied or moved while running.
    work: Channel[Work]
    output: OutputSink
    threads: seq[Thread[ptr WorkerPool]]
    state: PoolState


proc emitWorkerError(pool: ptr WorkerPool, runId, message: string) =
  ## Emits a terminal worker error without letting it escape the thread.
  try:
    pool[].output.emit(errorLine(runId, message))
  except CatchableError:
    discard


proc runWorker(pool: ptr WorkerPool) {.thread.} =
  ## Processes work until a stop message arrives.
  while true:
    let work = pool[].work.recv()

    case work.kind
    of wkStop:
      break

    of wkRun:
      try:
        runTrnrun(
          work.request.deckFile,
          work.request.runnerPath,
          work.request.runId,
          work.request.runnerArgs,
          pool[].output,
        )
      except CatchableError:
        emitWorkerError(
          pool,
          work.request.runId,
          getCurrentExceptionMsg(),
        )


proc stopWorkers(pool: var WorkerPool) =
  ## Stops and joins all workers in the pool.
  for _ in 0 ..< pool.threads.len:
    pool.work.send(Work(kind: wkStop))

  for index in 0 ..< pool.threads.len:
    joinThread(pool.threads[index])

  pool.threads = @[]


proc start*(pool: var WorkerPool, maxConcurrent: int, maxPending: int = 0) =
  ## Starts the worker pool. A positive `maxPending` bounds the pending queue.
  if maxConcurrent < 1:
    raise newException(ValueError, "maxConcurrent must be at least 1")

  if maxPending < 0:
    raise newException(ValueError, "maxPending must be at least 0")

  if pool.state != psNew:
    raise newException(ValueError, "worker pool is single-use")

  pool.state = psStopped

  pool.output.initOutputSink()

  try:
    pool.work.open(maxPending)

    {.push warning[ProveInit]: off, warning[Uninit]: off.}
    pool.threads = newSeq[Thread[ptr WorkerPool]](maxConcurrent)

    for index in 0 ..< maxConcurrent:
      try:
        createThread(pool.threads[index], runWorker, addr pool)
      except CatchableError:
        pool.threads.setLen(index)
        raise
    {.pop.}

    pool.state = psRunning

  except CatchableError:
    stopWorkers(pool)
    pool.output.deinitOutputSink()
    raise


proc submit*(pool: var WorkerPool, request: RunRequest) =
  ## Queues a request, blocking while a bounded pending queue is full.
  if pool.state != psRunning:
    raise newException(ValueError, "worker pool is not running")

  pool.work.send(Work(kind: wkRun, request: request))


proc shutdown*(pool: var WorkerPool) =
  ## Drains accepted work, stops the workers, and waits for them to exit.
  ## Safe to call before `start` or more than once.
  ##
  ## The channel stays open to avoid a Nim 2.2 ORC crash when closing channels
  ## that transported moved strings.
  if pool.state != psRunning:
    return

  pool.state = psStopped

  try:
    stopWorkers(pool)
  finally:
    pool.output.deinitOutputSink()
