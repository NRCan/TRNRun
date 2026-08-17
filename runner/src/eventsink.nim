## eventsink.nim - delivery destinations for structured simulation events.
##
## An event sink belongs to one simulation and receives its events in emission
## order. Simulation code does not know whether a sink writes JSON, collects
## events for a test, or forwards them to another process.

import ./events

type
  EventSink* = proc(event: SimulationEvent) {.closure.}
    ## Synchronous destination for events produced by one simulation.

proc stdoutEventSink*(): EventSink =
  ## Creates a sink that writes and immediately flushes one JSON event per line.
  result = proc(event: SimulationEvent) =
    stdout.writeLine(event.toJsonLine())
    stdout.flushFile()

proc jsonlEventSink*(path: string): EventSink =
  ## Creates a best-effort JSONL sink, replacing content from a previous run.
  try:
    writeFile(path, "")
  except CatchableError:
    raise newException(
      IOError,
      "Could not initialize JSONL file '" & path & "': " & getCurrentExceptionMsg(),
    )

  result = proc(event: SimulationEvent) =
    try:
      let file = open(path, fmAppend)
      defer: file.close()
      file.writeLine(event.toJsonLine())
    except CatchableError:
      stderr.writeLine(
        "[EventSink] Could not write JSONL event: ", getCurrentExceptionMsg()
      )

proc fanoutEventSink*(sinks: openArray[EventSink]): EventSink =
  ## Creates a sink that forwards every event to each child sink in order.
  let children = @sinks
  result = proc(event: SimulationEvent) =
    for sink in children:
      sink(event)
