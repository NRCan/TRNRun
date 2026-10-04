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

  WorkerPool* = object
    ## Owned by the scheduler thread. Its address must remain stable while
    ## workers are running because each worker receives `ptr Channel[Work]`.
    work: Channel[Work]
    threads: seq[Thread[WorkerContext]]

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
    runId, work.deckFile, work.trnrunPath, work.trnrunArgs, onLaunch, onOutput
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
  ## Runs work until the circulating stop sentinel arrives.
  while true:
    let work = context.work[].recv()
    case work.kind
    of wkStop:
      context.work[].send(Work(kind: wkStop))
      break
    of wkRun:
      runSimulation(context, work)

# Public API

proc shutdown*(pool: var WorkerPool) =
  ## Runs work submitted before this call, then stops and joins every worker.
  ## Safe before `start` and after an earlier shutdown.
  if pool.threads.len == 0:
    return

  pool.work.send(Work(kind: wkStop))
  for index in 0 ..< pool.threads.len:
    joinThread(pool.threads[index])
  pool.threads.setLen(0)

proc start*(pool: var WorkerPool, workers: int, inbox: ptr Channel[Message]) =
  ## Starts `workers` threads that report to `inbox`.
  pool.work.open()

  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  pool.threads = newSeq[Thread[WorkerContext]](workers)
  for index in 0 ..< workers:
    let context = WorkerContext(work: addr pool.work, inbox: inbox)
    try:
      createThread(pool.threads[index], runWorker, context)
    except CatchableError:
      pool.threads.setLen(index)
      pool.shutdown()
      raise
  {.pop.}

proc submit*(pool: var WorkerPool, work: Work) =
  ## Hands run work to the next free worker.
  pool.work.send(work)
