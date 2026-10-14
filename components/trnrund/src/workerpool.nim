## Captures TRNRun output on a fixed pool of worker threads.
##
## Workers take work from one shared channel and report to the scheduler inbox.
## The pool does not track capacity; the scheduler submits at most one run per
## worker. Shutdown finishes submitted work, then stops every worker.
##
## The work channel remains open to avoid a Nim 2.2 ORC crash when closing
## channels that transported moved strings, so start a pool only once.

import ./messages
import ./trnrun

type
  WorkerContext = object
    ## What each worker thread receives at start.
    work: ptr Channel[Work]
    inbox: ptr Channel[Message]

  WorkerPool* = object
    ## Fixed set of worker threads fed from one shared work channel.
    ##
    ## Owned by the scheduler thread. Its address must stay stable while
    ## workers run, since each holds a `ptr Channel[Work]` into it.
    work: Channel[Work]
    threads: seq[Thread[WorkerContext]]

# Worker

proc readRun(context: WorkerContext, work: Work) =
  ## Reports each output line of one run, then exactly one `mkExited`.
  let
    inbox = context.inbox
    runId = work.runId

  proc onOutput(line: string) {.gcsafe, raises: [].} =
    inbox[].send(Message(kind: mkOutput, runId: runId, line: line))

  let outcome = captureOutput(work.output, work.process, onOutput)
  inbox[].send(
    Message(kind: mkExited, runId: runId, exitCode: outcome.exitCode, error: outcome.error)
  )

proc runWorker(context: WorkerContext) {.thread.} =
  ## Reads runs until a stop message arrives.
  while true:
    let work = context.work[].recv()
    case work.kind
    of wkStop:
      break
    of wkRead:
      readRun(context, work)

# Public API

proc shutdown*(pool: var WorkerPool) =
  ## Finishes submitted work, then stops and joins every worker. Safe to repeat.
  for _ in pool.threads:
    pool.work.send(Work(kind: wkStop))
  for thread in pool.threads.mitems:
    joinThread(thread)
  pool.threads.setLen(0)

proc start*(pool: var WorkerPool, workers: int, inbox: ptr Channel[Message]) =
  ## Starts `workers` threads that report to `inbox`.
  pool.work.open()

  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  pool.threads = newSeq[Thread[WorkerContext]](workers)
  for index in 0 ..< workers:
    let context = WorkerContext(work: addr pool.work, inbox: inbox)
    createThread(pool.threads[index], runWorker, context)
  {.pop.}

proc submit*(pool: var WorkerPool, work: Work) =
  ## Hands `wkRead` work to the next free worker.
  pool.work.send(work)
