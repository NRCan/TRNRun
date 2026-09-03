## Defines the merged destination for forwarded child output.
##
## Every worker writes through one `OutputSink`, which holds a lock across the
## whole write so lines from concurrent runs are never torn or interleaved.
## Order within a single run is preserved; order between runs is not defined.

import std/locks

type OutputSink* = object
  ## Serializes writes to queue stdout across worker threads.
  lock: Lock


proc initOutputSink*(sink: var OutputSink) =
  ## Prepares `sink` for use. Call once, before any worker starts.
  ##
  ## Takes a `var` rather than returning a value because the underlying lock
  ## must not be copied or moved once initialized.
  initLock(sink.lock)

proc deinitOutputSink*(sink: var OutputSink) =
  ## Releases `sink`. Call only after every worker has been joined.
  deinitLock(sink.lock)

proc emit*(sink: var OutputSink, line: string) {.gcsafe.} =
  ## Writes one complete line to stdout and flushes it.
  ##
  ## A wrapper that dies closes queue stdin too, so stdin EOF is what ends this
  ## process; the job object then terminates every child. Broken-pipe detection
  ## cannot be layered on top of this write: `flushFile` discards the C `fflush`
  ## result, so a dead reader never surfaces as an `IOError` here. The handler
  ## below only stops a stdio error from being swallowed by the calling worker.
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
