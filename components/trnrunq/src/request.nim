## Defines the queue request surface.
##
## Owns the wire vocabulary a wrapper writes to queue stdin: one JSON object per
## line, and the rules that turn it into a `RunRequest`. Adding a request field
## means touching this module and nothing else.

import std/json

type RunRequest* = object
  ## One simulation request accepted from queue stdin.
  runId*: string ## Opaque identifier `trnrun` attaches to every event it emits.
  deckFile*: string ## `.dck` or `.trd` deck to simulate.
  runnerPath*: string ## Runner executable used for this request.
  runnerArgs*: seq[string] ## Extra arguments forwarded to the runner.


proc requireString(node: JsonNode, key: string): string =
  ## Returns `key` from `node`.
  ##
  ## Raises `ValueError` if the key is absent or is not a JSON string.
  result = ""
  if not node.hasKey(key) or node[key].kind != JString:
    raise newException(ValueError, "'" & key & "' must be a string")
  result = node[key].getStr()

proc parseRequest*(line: string): RunRequest =
  ## Parses one stdin line into a request.
  ##
  ## Validates shape only: field presence, JSON types, and a non-empty `runId`.
  ## Paths are resolved and checked later, on the worker thread that runs the
  ## request, so a queue accepting a request is not a claim that it can run.
  ## Raises `ValueError` for any malformed line.
  result = default(RunRequest)
  let node = parseJson(line)
  if node.kind != JObject:
    raise newException(ValueError, "Request must be a JSON object")

  result.runId = node.requireString("runId")
  result.deckFile = node.requireString("deckFile")
  result.runnerPath = node.requireString("runnerPath")
  if result.runId.len == 0:
    raise newException(ValueError, "'runId' must not be empty")

  if node.hasKey("runnerArgs"):
    if node["runnerArgs"].kind != JArray:
      raise newException(ValueError, "'runnerArgs' must be an array of strings")
    for argument in node["runnerArgs"]:
      if argument.kind != JString:
        raise newException(ValueError, "'runnerArgs' must contain only strings")
      result.runnerArgs.add(argument.getStr())
