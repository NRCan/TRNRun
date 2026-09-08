## Formats queue-generated protocol events.
##
## Events use the same line-oriented JSON stream as output produced by the
## runner, allowing callers to consume both through one stdout reader.

import std/[json, options, times]

proc errorLine*(runId, message: string): string =
  ## Returns a runner-compatible terminal error event.
  result = $(%*{
    "kind": "STATUS",
    "timestamp": now().format("yyyy-MM-dd'T'HH:mm:ss"),
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
    "timestamp": now().format("yyyy-MM-dd'T'HH:mm:ss"),
    "runId": runId,
  })

proc completedLine*(runId: string, exitCode: Option[int]): string =
  ## Returns the event marking an accepted request as fully complete.
  result = $(%*{
    "kind": "QUEUE",
    "event": "COMPLETED",
    "timestamp": now().format("yyyy-MM-dd'T'HH:mm:ss"),
    "runId": runId,
    "exitCode": (if exitCode.isSome: %exitCode.get() else: newJNull()),
  })
