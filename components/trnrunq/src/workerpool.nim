## Runs queued requests on a fixed pool of worker threads.
##
## Each worker owns one child at a time and forwards its output through a shared,
## synchronized sink. A positive `maxPending` bounds the pending channel; zero
## leaves it unbounded. Shutdown drains queued work before joining the workers.
##
## Pools are single-use because their channel remains open to avoid a Nim 2.2
## ORC crash when closing channels that transported moved strings.

import std/options

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
    ## Owned by one supervisor thread. Its address must remain stable while
    ## workers are running because each worker receives `ptr WorkerPool`.
    work: Channel[Work]
    output: OutputSink
    threads: seq[Thread[ptr WorkerPool]]
    state: PoolState


proc runWorker(pool: ptr WorkerPool) {.thread.} =
  ## Processes work until the circulating stop sentinel arrives.
  while true:
    let work = pool[].work.recv()

    case work.kind
    of wkStop:
      pool[].work.send(Work(kind: wkStop))
      break

    of wkRun:
      var exitCode = none(int)

      try:
        exitCode = runTrnrun(
          work.request.deckFile,
          work.request.runnerPath,
          work.request.runId,
          work.request.runnerArgs,
          pool[].output,
        )
      except CatchableError:
        pool[].output.emit(errorLine(work.request.runId, getCurrentExceptionMsg()))

      pool[].output.emit(completedLine(work.request.runId, exitCode))


proc stopWorkers(pool: var WorkerPool) =
  ## Stops every worker and joins its thread.
  if pool.threads.len == 0:
    return

  pool.work.send(Work(kind: wkStop))

  for index in 0 ..< pool.threads.len:
    joinThread(pool.threads[index])

  pool.threads.setLen(0)


proc start*(pool: var WorkerPool, maxConcurrent: int, maxPending: int = 0) =
  ## Starts the worker pool.
  ##
  ## At most `maxConcurrent` requests run simultaneously. A positive
  ## `maxPending` allows that many additional requests in the channel.
  if maxConcurrent < 1:
    raise newException(ValueError, "maxConcurrent must be at least 1")

  if maxPending < 0:
    raise newException(ValueError, "maxPending must be at least 0")

  if pool.state != psNew:
    raise newException(ValueError, "worker pool is single-use")

  # A failed startup also consumes the single-use pool.
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
  ## Queues one request and acknowledges it after channel admission.
  ##
  ## A bounded channel blocks `send` while full, so `ACCEPTED` is not emitted
  ## until capacity is available. A worker may begin before the acknowledgment;
  ## wrappers must register and route the `runId` before submitting.
  if pool.state != psRunning:
    raise newException(ValueError, "worker pool is not running")

  let runId = request.runId
  pool.work.send(Work(kind: wkRun, request: request))
  pool.output.emit(acceptedLine(runId))


proc shutdown*(pool: var WorkerPool) =
  ## Drains accepted work and releases worker resources.
  ##
  ## Safe before `start` and after an earlier shutdown. The channel deliberately
  ## remains open because closing it triggers a Nim 2.2 ORC failure.
  if pool.state != psRunning:
    return

  pool.state = psStopped

  stopWorkers(pool)
  pool.output.deinitOutputSink()
