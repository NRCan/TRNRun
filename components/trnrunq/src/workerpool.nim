## Runs queued requests on a fixed pool of worker threads.
##
## Each worker owns one child at a time and forwards its output through a shared,
## synchronized sink. A one-slot channel hands requests to available workers,
## which acknowledge pickup before launching. Shutdown drains submitted work.
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
      pool[].output.emit(acceptedLine(work.request.runID))
      var exitCode = none(int)

      try:
        exitCode = runTrnrun(
          work.request.deckFile,
          work.request.runnerPath,
          work.request.runID,
          work.request.runnerArgs,
          pool[].output,
        )
      except CatchableError:
        pool[].output.emit(errorLine(work.request.runID, getCurrentExceptionMsg()))

      pool[].output.emit(completedLine(work.request.runID, exitCode))


proc stopWorkers(pool: var WorkerPool) =
  ## Stops every worker and joins its thread.
  if pool.threads.len == 0:
    return

  pool.work.send(Work(kind: wkStop))

  for index in 0 ..< pool.threads.len:
    joinThread(pool.threads[index])

  pool.threads.setLen(0)


proc start*(pool: var WorkerPool, maxConcurrent: int) =
  ## Starts at most `maxConcurrent` simultaneous runners with a one-slot handoff.
  if maxConcurrent < 1:
    raise newException(ValueError, "maxConcurrent must be at least 1")


  if pool.state != psNew:
    raise newException(ValueError, "worker pool is single-use")

  # A failed startup also consumes the single-use pool.
  pool.state = psStopped
  pool.output.initOutputSink()


  try:
    pool.work.open(1)

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
  ## Hands off one request, blocking while the channel is full.
  ## The receiving worker emits `ACCEPTED` before any runner output.
  if pool.state != psRunning:
    raise newException(ValueError, "worker pool is not running")

  pool.work.send(Work(kind: wkRun, request: request))


proc shutdown*(pool: var WorkerPool) =
  ## Drains submitted work and releases worker resources.
  ##
  ## Safe before `start` and after an earlier shutdown. The channel deliberately
  ## remains open because closing it triggers a Nim 2.2 ORC failure.
  if pool.state != psRunning:
    return

  pool.state = psStopped

  stopWorkers(pool)

  pool.output.deinitOutputSink()
