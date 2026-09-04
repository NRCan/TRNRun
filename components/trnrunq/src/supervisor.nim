## Orchestrates the queue lifecycle.
##
## Guards process lifetime, starts the worker pool, reads one JSON request per
## line from stdin, and shuts the pool down. Child output is forwarded unchanged
## to stdout. Stdin EOF ends submission and waits for every accepted request.

when not defined(windows):
  {.error: "supervisor.nim is Windows-only.".}

import ./job
import ./request
import ./workerpool


proc serve*(maxConcurrent: int, maxPending: int = 0) =
  ## Accepts requests until stdin reaches EOF and waits for every accepted run.
  if maxConcurrent < 1:
    raise newException(ValueError, "maxConcurrent must be at least 1")
  if maxPending < 0:
    raise newException(ValueError, "maxPending must be at least 0")

  initJobGuard()

  var pool = default(WorkerPool)
  try:
    pool.start(maxConcurrent, maxPending)

    var line = ""
    while stdin.readLine(line):
      if line.len == 0:
        continue
      pool.submit(parseRequest(line))
  finally:
    pool.shutdown()
