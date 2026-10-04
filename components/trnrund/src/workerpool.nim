## Runs submitted work on a fixed pool of worker threads.
##
## Workers take work from one shared channel and report to the scheduler inbox.
## The pool does not track capacity; the scheduler submits at most one run per
## worker. Shutdown finishes submitted work, then stops every worker.
##
## The work channel remains open to avoid a Nim 2.2 ORC crash when closing
## channels that transported moved strings, so a pool is started only once.

import ./messages
import ./trnrun

type
  WorkerContext = object
    work: ptr Channel[Work]
    inbox: ptr Channel[Message]
    trnrunPath: string

  WorkerPool* = object
    ## Owned by the scheduler thread. Its address must remain stable while
    ## workers are running because each worker receives `ptr Channel[Work]`.
    work: Channel[Work]
    threads: seq[Thread[WorkerContext]]
    started: bool ## Remains true after shutdown or a failed thread startup.

# Worker

proc runSimulation(context: WorkerContext, work: Work) =
  ## Runs one simulation, posting `mkLaunched` once the child exists, one
  ## `mkOutput` per line, then exactly one `mkExited`.
  let
    inbox = context.inbox
    runId = work.runId

  proc onLaunch() {.gcsafe, raises: [].} =
    inbox[].send(Message(kind: mkLaunched, runId: runId))

  proc onOutput(line: string) {.gcsafe, raises: [].} =
    inbox[].send(Message(kind: mkOutput, runId: runId, line: line))

  let outcome = runTrnrun(
    runId, work.deckFile, context.trnrunPath, work.trnrunArgs, onLaunch, onOutput
  )
  inbox[].send(
    Message(
      kind: mkExited,
      runId: runId,
      exitCode: outcome.exitCode,
      error: outcome.error,
    )
  )

proc runWorker(context: WorkerContext) {.thread.} =
  ## Runs work until a stop message arrives.
  while true:
    let work = context.work[].recv()
    case work.kind
    of wkStop:
      break
    of wkRun:
      runSimulation(context, work)

# Public API

proc shutdown*(pool: var WorkerPool) =
  ## Runs work submitted before this call, then stops and joins every worker.
  ## Safe before `start` and after an earlier shutdown.
  if pool.threads.len == 0:
    return

  for index in 0 ..< pool.threads.len:
    pool.work.send(Work(kind: wkStop))
  for index in 0 ..< pool.threads.len:
    joinThread(pool.threads[index])
  pool.threads.setLen(0)

proc start*(
    pool: var WorkerPool, trnrunPath: string, workers: int, inbox: ptr Channel[Message]
) =
  ## Starts `workers` threads that run the TRNRun at `trnrunPath` and report to
  ## `inbox`. Raises ValueError if already started, workers < 1, or inbox is nil.
  if pool.started:
    raise newException(ValueError, "Worker pool has already been started")
  if workers < 1:
    raise newException(ValueError, "'workers' must be at least 1")
  if inbox == nil:
    raise newException(ValueError, "Worker pool inbox must not be nil")

  pool.work.open()
  pool.started = true

  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  pool.threads = newSeq[Thread[WorkerContext]](workers)
  for index in 0 ..< workers:
    let context =
      WorkerContext(work: addr pool.work, inbox: inbox, trnrunPath: trnrunPath)
    try:
      createThread(pool.threads[index], runWorker, context)
    except CatchableError:
      pool.threads.setLen(index)
      pool.shutdown()
      raise
  {.pop.}

proc submit*(pool: var WorkerPool, work: Work) =
  ## Hands run work to the next free worker.
  ## Raises ValueError if the pool is not running or work is not wkRun.
  if pool.threads.len == 0:
    raise newException(ValueError, "Worker pool is not running")
  if work.kind != wkRun:
    raise newException(ValueError, "Only run work can be submitted")
  pool.work.send(work)
