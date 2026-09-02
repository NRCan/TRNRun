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
  if writer == nil or writer.file == nil:
    return

  let file = writer.file
  writer.file = nil
  file.close()

proc newJsonlWriter*(): JsonlWriter =
  ## Returns a writer with no file attached.
  ##
  ## Writes are ignored until `attachEventFile` opens one, so the writer can be
  ## wired into a sink before the output path is known.
  new(result)

proc attachEventFile*(
    writer: JsonlWriter, deckFile: string, writeEvents: var bool
) =
  ## Opens deck-specific event output into `writer` when requested.
  ##
  ## Clears `writeEvents` when the file cannot be opened, keeping the SETTING
  ## event honest that nothing will be written to a file.
  if writer == nil or not writeEvents:
    return

  let path = deckFile.changeFileExt("jsonl")
  if open(writer.file, path, fmWrite, bufSize = 0):
    return

  writeEvents = false
  try:
    stderr.writeLine("[JsonlWriter] Could not open event file (logging disabled): ", path)
  except IOError:
    discard

proc writeLine(writer: JsonlWriter, line: string) =
  ## Writes `line` followed by a newline.
  ##
  ## On failure the writer is closed and the error reported, so subsequent
  ## writes are ignored. Writing to `nil` or a closed writer has no effect.
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
  ## Returns a sink that numbers events from 1, optionally attaches `runId`,
  ## writes and immediately flushes each JSON line to stdout, and optionally
  ## mirrors the same line to `writer`. Each returned sink owns an independent
  ## sequence starting at 1.
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
          stderr.writeLine("[JsonlWriter] Could not write event to stdout (stdout disabled): ", message)
        except IOError:
          discard

    writer.writeLine(line)
