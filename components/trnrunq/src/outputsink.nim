## Defines the merged destination for queue and child output.
##
## Every worker writes through one `OutputSink`, which holds a lock across each
## complete stdout line so concurrent runs never tear or interleave output.

import std/locks

type OutputSink* = object
  ## Serializes writes to queue stdout across worker threads.
  lock: Lock


proc initOutputSink*(sink: var OutputSink) =
  ## Initializes `sink` in place, since its lock must not move; call before any worker starts.
  initLock(sink.lock)

proc deinitOutputSink*(sink: var OutputSink) =
  ## Releases `sink`. Call only after every worker has been joined.
  deinitLock(sink.lock)

proc emit*(sink: var OutputSink, line: string) {.gcsafe.} =
  ## Writes one line to stdout under the lock and flushes it; exits the process on a stdio error.
  # A dead reader never raises here (`flushFile` drops the `fflush` result); stdin EOF ends
  # the queue instead. The handler only keeps a stdio error from being swallowed by a worker.
  var failed = false

  acquire(sink.lock)
  try:
    stdout.writeLine(line)
    stdout.flushFile()
  except IOError:
    failed = true
  finally:
    release(sink.lock)

  if failed:
    quit(1)
