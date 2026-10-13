## Runs submitted work on a fixed pool of worker threads.
##
## Workers take work from one shared channel and report to the scheduler inbox.
## The pool does not track capacity; the scheduler submits at most one run per
## worker. Shutdown finishes submitted work, then stops every worker.
##
## The work channel remains open to avoid a Nim 2.2 ORC crash when closing
## channels that transported moved strings, so start a pool only once.

import std/atomics
import ./messages
import ./trnrun

type
  WorkerContext = object
    ## What each worker thread receives at start.
    work: ptr Channel[Work]
    inbox: ptr Channel[Message]
    trnrunPath: string

  WorkerPool* = object
    ## Fixed set of worker threads fed from one shared work channel.
    ##
    ## Owned by the scheduler thread. Its address must stay stable while
    ## workers run, since each holds a `ptr Channel[Work]` into it.
    work: Channel[Work]
    threads: seq[Thread[WorkerContext]]

# Worker

proc runSimulation(context: WorkerContext, work: Work) =
  ## Runs one simulation and reports it to the scheduler inbox.
  ##
  ## Posts `mkLaunched` once the child exists, one `mkOutput` per line, then
  ## exactly one `mkExited`, even when TRNRun fails to launch or is cancelled.
  ## The cancel flag is not read after `mkExited` is sent, since the scheduler
  ## then frees it.
  let
    inbox = context.inbox
    runId = work.runId
    cancel = work.cancel

  proc onLaunch() {.gcsafe, raises: [].} =
    inbox[].send(Message(kind: mkLaunched, runId: runId))

  proc onOutput(line: string) {.gcsafe, raises: [].} =
    inbox[].send(Message(kind: mkOutput, runId: runId, line: line))

  proc isCancelled(): bool {.gcsafe, raises: [].} =
    cancel[].load()

  let outcome = runTrnrun(
    runId, work.deckFile, context.trnrunPath, work.trnrunArgs, onLaunch, onOutput, isCancelled
  )
  inbox[].send(
    Message(
      kind: mkExited,
      runId: runId,
      exitCode: outcome.exitCode,
      error: outcome.error,
      cancelled: outcome.cancelled,
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
  ## Finishes submitted work, then stops and joins every worker. Safe to repeat.
  for _ in pool.threads:
    pool.work.send(Work(kind: wkStop))
  for thread in pool.threads.mitems:
    joinThread(thread)
  pool.threads.setLen(0)

proc start*(
    pool: var WorkerPool, trnrunPath: string, workers: int, inbox: ptr Channel[Message]
) =
  ## Starts `workers` threads that run the TRNRun at `trnrunPath` and report
  ## to `inbox`.
  pool.work.open()

  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  pool.threads = newSeq[Thread[WorkerContext]](workers)
  for index in 0 ..< workers:
    let context =
      WorkerContext(work: addr pool.work, inbox: inbox, trnrunPath: trnrunPath)
    createThread(pool.threads[index], runWorker, context)
  {.pop.}

proc submit*(pool: var WorkerPool, work: Work) =
  ## Hands `wkRun` work, with its cancel flag allocated, to the next free worker.
  pool.work.send(work)
