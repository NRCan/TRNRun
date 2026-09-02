## Adds queue routing metadata to TRNRun events and marks run completion.

import std/json


proc routeEvent*(runId: int, line: string): JsonNode =
  ## Parses one TRNRun JSONL event and adds its queue run identifier.
  result = parseJson(line)
  if result.kind != JObject:
    raise newException(ValueError, "Expected a JSON object")
  result["runId"] = %runId

proc exitEnvelope*(runId: int, message: string = ""): JsonNode =
  ## Marks the end of one run, optionally reporting a queue-owned failure.
  result = %*{
    "type": "exit",
    "runId": runId,
  }
  if message.len > 0:
    result["message"] = %message
