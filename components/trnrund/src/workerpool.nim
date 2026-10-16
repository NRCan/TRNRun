## Captures TRNRun output on a fixed pool of worker threads.
##
## Workers take work from one shared channel and report to the scheduler inbox.
## The pool does not track capacity; the scheduler submits at most one run per
## worker. Shutdown finishes submitted work, then stops every worker.
##
## The work channel remains open to avoid a Nim 2.2 ORC crash when closing
## channels that transported moved strings, so start a pool only once.

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
  ## Finishes submitted work, then stops and joins every worker. Safe to repeat.
  for _ in pool.threads:
    pool.work.send(Work(kind: wkStop))
  for thread in pool.threads.mitems:
    joinThread(thread)
  pool.threads.setLen(0)
