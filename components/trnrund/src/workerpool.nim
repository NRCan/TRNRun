## Captures TRNRun output on a fixed pool of worker threads.
##
## Workers take work from one shared channel and report to the scheduler inbox.
## The pool does not track capacity; the scheduler submits at most one run per
## worker. Shutdown finishes submitted work, stops every worker, then closes the
## work channel. The scheduler inbox is not the pool's to close.

import ./[messages, threadstart, trnrun]

type
  WorkerContext = object
    ## The channels one worker reads from and reports to.
    work: ptr Channel[Work]
    inbox: ptr Channel[Message]

  WorkerPool* = object
    ## Worker threads capturing TRNRun output; must not move while they hold a pointer into it.
    work: Channel[Work]
    threads: seq[Thread[WorkerContext]]

# Worker

proc readRun(context: WorkerContext, work: Work) =
  ## Reports each output line of one run, then exactly one `mkExited`.
  let
    inbox = context.inbox
    runId = work.runId

  proc onOutput(line: string) {.gcsafe, raises: [].} =
    ## Posts one output line of this run.
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

proc start*(pool: var WorkerPool, workers: int, inbox: ptr Channel[Message]) =
  ## Starts `workers` threads that report to `inbox`.
  pool.work.open()
  pool.threads = newSeq[Thread[WorkerContext]](workers)
  for thread in pool.threads.mitems:
    thread.startThread(runWorker, WorkerContext(work: addr pool.work, inbox: inbox))

proc submit*(pool: var WorkerPool, work: Work) =
  ## Hands `wkRead` work to the next free worker; returns at once.
  pool.work.send(work)

proc shutdown*(pool: var WorkerPool) =
  ## Finishes submitted work, stops and joins every worker, then closes the work channel.
  if pool.threads.len == 0:
    return
  for _ in pool.threads:
    pool.work.send(Work(kind: wkStop))
  for thread in pool.threads.mitems:
    joinThread(thread)
  pool.threads.setLen(0)
  pool.work.close()
