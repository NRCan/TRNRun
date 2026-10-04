## Defines the daemon request surface.
##
## Owns the wire vocabulary a wrapper writes to daemon stdin: one JSON object
## per line naming a `cmd`, and the rules that turn it into a `Command`. A
## request may carry an `id` of any JSON type, which is echoed in its reply so
## callers can match replies that arrive out of order.
##
## Commands:
## - `submit`: queue a simulation (`runId`, `deckFile`, `runnerPath`, `runnerArgs`)
## - `snapshot`: report one simulation (`runId`)
## - `list`: report every simulation in submission order, or with `since`, only
##   those changed after that version
## - `wait`: reply once one simulation, or every simulation submitted so far,
##   has finished
## - `shutdown`: refuse new simulations and exit once drained

import std/[json, strutils]

type
  CommandKind* = enum
    ## Request discriminator. Values are JSON `cmd` tags.
    ckSubmit = "submit"
    ckSnapshot = "snapshot"
    ckList = "list"
    ckWait = "wait"
    ckShutdown = "shutdown"

  Command* = object
    ## One validated request. Fields unused by `kind` keep their defaults.
    kind*: CommandKind
    runId*: string ## Target simulation; empty selects every one for `wait`.
    deckFile*: string
    runnerPath*: string
    runnerArgs*: seq[string]
    since*: int ## `list` only: skip simulations unchanged since this version.


proc requestId*(node: JsonNode): JsonNode =
  ## Returns the caller's `id`, or JSON null when there is none.
  if node.kind == JObject and node.hasKey("id"): node["id"] else: newJNull()


proc requireString(node: JsonNode, key: string): string =
  ## Returns `key` from `node`.
  ##
  ## Raises `ValueError` if the key is absent or is not a JSON string.
  result = ""
  if not node.hasKey(key) or node[key].kind != JString:
    raise newException(ValueError, "'" & key & "' must be a string")
  result = node[key].getStr()


proc requireRunId(node: JsonNode): string =
  result = node.requireString("runId")
  if result.len == 0:
    raise newException(ValueError, "'runId' must not be empty")


proc optionalRunId(node: JsonNode): string =
  ## Returns `runId`, or an empty string when absent. Present means non-empty,
  ## so a blank id can never select every simulation by accident.
  if node.hasKey("runId"): node.requireRunId() else: ""


proc optionalNatural(node: JsonNode, key: string, default: int): int =
  result = default
  if node.hasKey(key):
    if node[key].kind != JInt or node[key].getInt() < 0:
      raise newException(ValueError, "'" & key & "' must be a non-negative integer")
    result = node[key].getInt()


proc optionalStrings(node: JsonNode, key: string): seq[string] =
  result = @[]
  if node.hasKey(key):
    if node[key].kind != JArray:
      raise newException(ValueError, "'" & key & "' must be an array of strings")
    for item in node[key]:
      if item.kind != JString:
        raise newException(ValueError, "'" & key & "' must contain only strings")
      result.add(item.getStr())


proc parseCommand*(node: JsonNode): Command =
  ## Validates one parsed request line.
  ##
  ## Validates shape only; the daemon resolves and checks paths when it
  ## handles `submit`. Raises `ValueError` for any malformed request.
  result = default(Command)
  if node.kind != JObject:
    raise newException(ValueError, "Request must be a JSON object")

  let name = node.requireString("cmd")
  try:
    result.kind = parseEnum[CommandKind](name)
  except ValueError:
    raise newException(ValueError, "Unknown command: " & name)

  case result.kind
  of ckSubmit:
    result.runId = node.requireRunId()
    result.deckFile = node.requireString("deckFile")
    result.runnerPath = node.requireString("runnerPath")
    result.runnerArgs = node.optionalStrings("runnerArgs")
  of ckSnapshot:
    result.runId = node.requireRunId()
  of ckList:
    result.since = node.optionalNatural("since", 0)
  of ckWait:
    result.runId = node.optionalRunId()
  of ckShutdown:
    discard
