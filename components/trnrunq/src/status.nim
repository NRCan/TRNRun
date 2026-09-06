## Formats queue-generated runner status events.
##
## Events use the same line-oriented JSON format as output produced by the
## runner, allowing callers to consume both through one stream.

import std/[json, times]


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
