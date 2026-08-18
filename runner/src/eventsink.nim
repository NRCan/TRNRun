## eventsink.nim - delivery destinations for structured simulation events.
##
## An `EventSink` receives typed simulation events in emission order. JSONL
## writers own their output file so callers control its lifetime explicitly.

import ./events

type
  EventSink* = proc(event: SimulationEvent) {.closure.}
    ## Synchronous destination for typed events produced by one simulation.

  JsonlWriter* = ref object
    ## Best-effort writer that owns an open JSONL output file.
    file: File

proc stdoutEventSink*(): EventSink =
  ## Creates a sink that writes and immediately flushes one JSON event per line.
  result = proc(event: SimulationEvent) =
    stdout.writeLine(event.toJsonLine())
    stdout.flushFile()

proc openJsonlWriter*(path: string): JsonlWriter =
  ## Creates a writer that truncates `path` and keeps it open until closed.
  ## The file is unbuffered so write failures are reported synchronously.
  new(result)
  if not open(result.file, path, fmWrite, bufSize = 0):
    raise newException(IOError, "Could not open JSONL file '" & path & "'")

proc close*(writer: JsonlWriter) =
  ## Closes the owned output file. Repeated calls have no effect.
  if writer != nil and writer.file != nil:
    writer.file.close()
    writer.file = nil

proc write*(writer: JsonlWriter, line: string) =
  ## Writes one serialized event line and disables the writer on failure.
  ## The trail exists to survive a crash, so a failed write is reported once
  ## and then ignored rather than aborting the simulation producing it.
  if writer == nil or writer.file == nil:
    return

  try:
    # One write per event: `writeLine` emits the newline as a second call, so
    # an unbuffered trail can end mid-record when the run dies between them.
    writer.file.write(line & "\n")
  except IOError:
    let message = getCurrentExceptionMsg()
    writer.close()
    try:
      stderr.writeLine(
        "[JsonlWriter] Could not write event (writer disabled): ", message
      )
    except IOError:
      discard # stderr is gone too, so there is nowhere left to report.
