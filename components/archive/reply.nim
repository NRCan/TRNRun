## Formats and writes daemon replies.
##
## Every request gets exactly one reply line on stdout carrying its `id`:
##
##   {"id":1,"ok":true,"result":{...}}
##   {"id":1,"ok":false,"error":"..."}
##
## Only the daemon thread writes stdout, so replies never tear or interleave.

import std/json


proc okReply*(id, payload: JsonNode): JsonNode =
  %*{"id": id, "ok": true, "result": payload}


proc errorReply*(id: JsonNode, message: string): JsonNode =
  %*{"id": id, "ok": false, "error": message}


proc writeReply*(reply: JsonNode) =
  ## Writes one complete line to stdout and flushes it.
  ##
  ## Raises `IOError` when stdout fails; the daemon treats that as fatal.
  stdout.writeLine($reply)
  stdout.flushFile()
