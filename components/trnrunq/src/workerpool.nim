## Runs accepted requests on a fixed pool of worker threads.
##
## One thread per concurrent run is required rather than chosen: `osproc`
## exposes child stdout as a blocking read on an anonymous pipe, which supports
## neither `select` nor Windows IOCP, so following N children concurrently needs
## N blocked readers.
##
## With `maxPending == 0`, submission never blocks and the work channel is
## unbounded. A positive limit applies backpressure by blocking submission when
## that many requests are waiting for a worker.

import ./outputsink
import ./request
import ./trnrun

type
  WorkKind = enum
    wkRun
    wkStop

  Work = object
    ## One channel message: a request to run, or a sentinel to stop a worker.
    case kind: WorkKind
    of wkRun:
      request: RunRequest
    of wkStop:
      discard

  WorkerPool* = object
    ## Fixed pool of workers sharing one work channel and one output sink.
    ##
    ## Workers receive `addr` of this object, so it must outlive them: it may
    ## not be copied or moved, and `shutdown` must run before its frame ends.
    work: Channel[Work]
    workInitialized: bool
    output: OutputSink
    outputInitialized: bool
    threads: seq[Thread[ptr WorkerPool]]
    startedThreads: int


proc runWorker(pool: ptr WorkerPool) {.thread.} =
  ## Consumes work until a stop sentinel arrives.
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
        discard


proc start*(pool: var WorkerPool, maxConcurrent: int, maxPending: int = 0) =
  ## Initializes queue output and starts `maxConcurrent` workers.
  ## A positive `maxPending` bounds requests waiting in the work channel; zero
  ## keeps the channel unbounded.
  ##
  ## Thread storage is allocated before any thread is created so a partly
  ## started pool still shuts down cleanly.
  if maxConcurrent < 1:
    raise newException(ValueError, "maxConcurrent must be at least 1")
  if maxPending < 0:
    raise newException(ValueError, "maxPending must be at least 0")

  pool.startedThreads = 0
  pool.output.initOutputSink()
  pool.outputInitialized = true
  pool.work.open(maxPending)
  pool.workInitialized = true
  pool.threads = newSeq[Thread[ptr WorkerPool]](maxConcurrent)

  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  for thread in pool.threads.mitems:
    createThread(thread, runWorker, addr pool)
    inc pool.startedThreads
  {.pop.}

proc submit*(pool: var WorkerPool, request: RunRequest) =
  ## Queues one request. Blocks only while a bounded pending queue is full.
  pool.work.send(Work(kind: wkRun, request: request))

proc shutdown*(pool: var WorkerPool) =
  ## Stops every worker and waits for the runs already accepted.
  ##
  ## Submission must have stopped before this is called. Channel order queues
  ## the sentinels behind every accepted request, so no worker stops while work
  ## remains. A pool that never started is left alone.
  if not pool.outputInitialized:
    return

  try:
    for _ in 0 ..< pool.startedThreads:
      pool.work.send(Work(kind: wkStop))

    for index in 0 ..< pool.startedThreads:
      joinThread(pool.threads[index])

    if pool.workInitialized:
      pool.work.close()
      pool.workInitialized = false
  finally:
    pool.output.deinitOutputSink()
    pool.outputInitialized = false
    pool.startedThreads = 0
