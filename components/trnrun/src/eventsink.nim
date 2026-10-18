## Defines destinations for structured simulation events.
##
## An `EventSink` receives typed events in emission order. A `JsonlWriter` owns
## its output file, allowing callers to control the file's lifetime explicitly.
##
## Event logging is best-effort: a destination that fails is reported once and
## then disabled, so a broken pipe or a full disk can never interrupt a running
## simulation.

import std/[json, os]
import ./events

type
  EventSink* = proc(event: SimulationEvent) {.closure, gcsafe.}
    ## Synchronous destination for events produced by a simulation.

  JsonlWriter* = ref object ## Writer that owns an open JSON Lines output file.
    file: File

proc close*(writer: JsonlWriter) =
  ## Closes the owned output file; a `nil` or already closed writer is a no-op.
  if writer == nil or writer.file == nil:
    return

  let file = writer.file
  writer.file = nil
  file.close()

proc newJsonlWriter*(): JsonlWriter =
  ## Returns a writer that ignores writes until `attachEventFile` gives it a file.
  new(result)

proc attachEventFile*(writer: JsonlWriter, deckFile: string): bool =
  ## Opens the deck's `.jsonl` file into `writer`; reports on stderr and returns false on failure.
  if writer == nil:
    return false

  let path = deckFile.changeFileExt("jsonl")
  if open(writer.file, path, fmWrite, bufSize = 0):
    return true

  result = false
  try:
    stderr.writeLine("[JsonlWriter] Could not open event file (logging disabled): ", path)
  except IOError:
    discard

proc writeLine(writer: JsonlWriter, line: string) =
  ## Writes `line`, closing the writer and reporting once on failure; no-op when closed.
  if writer == nil or writer.file == nil:
    return

  try:
    writer.file.writeLine(line)
  except IOError:
    let message = getCurrentExceptionMsg()
    try:
      writer.close()
    except IOError:
      discard
    try:
      stderr.writeLine("[JsonlWriter] Could not write event (writer disabled): ", message)
    except IOError:
      discard

proc stdoutEventSink*(writer: JsonlWriter = nil, runId: string = ""): EventSink =
  ## Returns a sink flushing `seq`-numbered JSON lines to stdout and mirroring them to `writer`.
  var
    sequence = 0
    stdoutUsable = true

  result = proc(event: SimulationEvent) {.gcsafe.} =
    inc sequence

    let node = event.toJson()
    node["seq"] = %sequence
    if runId.len > 0:
      node["runId"] = %runId
    let line = $node

    if stdoutUsable:
      try:
        stdout.writeLine(line)
        stdout.flushFile()
      except IOError:
        stdoutUsable = false
        let message = getCurrentExceptionMsg()
        try:
          stderr.writeLine(
            "[JsonlWriter] Could not write event to stdout (stdout disabled): ",
            message,
          )
        except IOError:
          discard

    writer.writeLine(line)
