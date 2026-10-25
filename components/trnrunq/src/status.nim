## Formats queue-generated protocol events.
##
## Events use the same line-oriented JSON stream as output produced by the
## runner, allowing callers to consume both through one stdout reader.

import std/[json, options, times]

const EventTimestampFormat = "yyyy-MM-dd'T'HH:mm:ss"

var
  eventTimeFormat {.threadvar.}: TimeFormat
  eventTimeFormatInitialized {.threadvar.}: bool

proc getEventTimeFormat(): TimeFormat {.gcsafe.} =
  ## Returns this thread's cached timestamp format, parsing it on first use.
  if not eventTimeFormatInitialized:
    eventTimeFormat = initTimeFormat(EventTimestampFormat)
    eventTimeFormatInitialized = true
  eventTimeFormat

proc formatEventTimestamp(timestamp: DateTime): string {.gcsafe.} =
  ## Formats `timestamp` in the wire format.
  timestamp.format(getEventTimeFormat())

proc errorLine*(runId, message: string): string =
  ## Returns a runner-compatible terminal error event.
  result = $(%*{
    "kind": "STATUS",
    "timestamp": now().formatEventTimestamp(),
    "status": "ERROR",
    "message": message,
    "seq": 1,
    "runId": runId,
  })

proc acceptedLine*(runId: string): string =
  ## Returns the event marking a request as picked up by a worker.
  result = $(%*{
    "kind": "QUEUE",
    "event": "ACCEPTED",
    "timestamp": now().formatEventTimestamp(),
    "runId": runId,
  })

proc completedLine*(runId: string, exitCode: Option[int]): string =
  ## Returns the event marking an accepted request as fully complete.
  result = $(%*{
    "kind": "QUEUE",
    "event": "COMPLETED",
    "timestamp": now().formatEventTimestamp(),
    "runId": runId,
    "exitCode": (if exitCode.isSome: %exitCode.get() else: newJNull()),
  })
