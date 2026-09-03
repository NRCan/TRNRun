## Runs accepted requests on a fixed pool of worker threads.
##
## One thread per concurrent run is required rather than chosen: `osproc`
## exposes child stdout as a blocking read on an anonymous pipe, which supports
## neither `select` nor Windows IOCP, so following N children concurrently needs
## N blocked readers.
##
## Submission never blocks. The work channel is unbounded, so accepting a
## request does not wait on execution progress.

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
    output: ptr OutputSink
    threads: seq[Thread[ptr WorkerPool]]


proc runWorker(pool: ptr WorkerPool) {.thread.} =
  ## Consumes work until a stop sentinel arrives.
  while true:
    let work = pool[].work.recv()
    case work.kind
    of wkStop:
      break
    of wkRun:
      let output = pool[].output
      let onOutput = proc(line: string) {.gcsafe.} =
        output.emit(line)

      try:
        runTrnrun(
          work.request.deckFile,
          work.request.runnerPath,
          work.request.runId,
          work.request.runnerArgs,
          onOutput,
        )
      except CatchableError:
        # A stdout ERROR event will report this in the final protocol.
        discard


proc start*(pool: var WorkerPool, output: ptr OutputSink, maxConcurrent: int) =
  ## Opens the work channel and starts `maxConcurrent` workers.
  ##
  ## The thread sequence is sized before any thread is created, so a pool that
  ## fails partway through still shuts down cleanly through `shutdown`.
  pool.work.open()
  pool.output = output
  pool.threads = newSeq[Thread[ptr WorkerPool]](maxConcurrent)

  {.push warning[ProveInit]: off, warning[Uninit]: off.}
  for index in 0 ..< pool.threads.len:
    createThread(pool.threads[index], runWorker, addr pool)
  {.pop.}

proc submit*(pool: var WorkerPool, request: RunRequest) =
  ## Queues one request. Returns without waiting for a worker to pick it up.
  pool.work.send(Work(kind: wkRun, request: request))

proc shutdown*(pool: var WorkerPool) =
  ## Stops every worker and waits for the runs already accepted.
  ##
  ## Channel order is what makes this safe to call at any time: the sentinels
  ## queue behind every pending request, so no worker stops while work remains.
  ## Joining a thread that was never created is a no-op, and a pool that never
  ## started is left alone.
  if pool.threads.len == 0:
    return

  for _ in 0 ..< pool.threads.len:
    pool.work.send(Work(kind: wkStop))

  for index in 0 ..< pool.threads.len:
    joinThread(pool.threads[index])

  # Explicit Channel.close crashes Nim 2.2 ORC after receiving moved strings.
  # This pool owns one channel for the process lifetime, so it is left open.
