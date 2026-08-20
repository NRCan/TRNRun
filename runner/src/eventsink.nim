## Defines destinations for structured simulation events.
##
## An `EventSink` receives typed events in emission order. A `JsonlWriter` owns
## its output file, allowing callers to control the file's lifetime explicitly.

import std/json
import ./events

type
  EventSink* = proc(event: SimulationEvent) {.closure, gcsafe.}
    ## Synchronous destination for events produced by a simulation.

  JsonLineSink* = proc(line: string) {.closure, gcsafe.}
    ## Synchronous destination for a serialized JSON line.

  JsonlWriter* = ref object
    ## Writer that owns an open JSON Lines output file.
    file: File

proc sequencedJsonLine(event: SimulationEvent, sequence: int): string =
  ## Serializes `event` as a compact single-line JSON object carrying `seq`,
  ## its position in the emission order.
  let node = event.toJson()
  node["seq"] = %sequence
  $node

proc sequencedEventSink*(lineSink: JsonLineSink): EventSink =
  ## Wraps a JSON-line destination with event serialization and sequencing.
  ##
  ## Each returned sink owns an independent sequence starting at 1. Assigning
  ## the number here, at the emission boundary, lets a consumer distinguish a
  ## dropped line from a pause in the stream.
  var sequence = 0
  result = proc(event: SimulationEvent) =
    inc sequence
    lineSink(event.sequencedJsonLine(sequence))

proc stdoutEventSink*(): EventSink =
  ## Returns a sink that writes each event to standard output as one JSON line,
  ## numbered from 1 in emission order. Each line is flushed immediately.
  result = sequencedEventSink(
    proc(line: string) =
      stdout.writeLine(line)
      stdout.flushFile()
  )

proc openJsonlWriter*(path: string): JsonlWriter =
  ## Opens `path` for unbuffered output, truncating any existing file.
  ##
  ## The returned writer owns the file until `close` is called. Raises
  ## `IOError` if the file cannot be opened.
  new(result)
  if not open(result.file, path, fmWrite, bufSize = 0):
    raise newException(IOError, "Could not open JSONL file '" & path & "'")

proc close*(writer: JsonlWriter) =
  ## Closes the owned output file.
  ##
  ## Calling `close` with `nil` or an already closed writer has no effect.
  if writer == nil:
    return

  let file = writer.file
  writer.file = nil

  if file != nil:
    file.close()

proc write*(writer: JsonlWriter, line: string) =
  ## Writes `line` followed by a newline.
  ##
  ## On failure, the error is reported to standard error and the writer is
  ## closed. Subsequent writes are ignored so event logging cannot interrupt
  ## the simulation. Writing to `nil` or a closed writer also has no effect.
  if writer == nil or writer.file == nil:
    return

  try:
    writer.file.write(line & "\n")
  except IOError:
    let message = getCurrentExceptionMsg()
    try:
      writer.close()
    except IOError:
      discard # Preserve the original write failure and keep the writer disabled.
    try:
      stderr.writeLine(
        "[JsonlWriter] Could not write event (writer disabled): ", message
      )
    except IOError:
      discard
