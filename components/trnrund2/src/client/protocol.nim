## Turns one client request line into one response line.
##
## A request is a JSON object with a `cmd`. Every response is a JSON object
## with `ok`; when `ok` is false it also has an `error` for humans. README.md
## lists the commands. Simulation work is delegated to `pool`.

import std/[json, options, sequtils, strutils]
import ../worker/pool
import ./validate

proc optionalField(
    request: JsonNode,
    name: string,
    kind: JsonNodeKind,
    expected: string,
): JsonNode =
  ## `request[name]`, or nil when missing or null; `InputError` if of another kind.
  result = request.getOrDefault(name)
  if result != nil and result.kind == JNull:
    result = nil
  if result != nil and result.kind != kind:
    raise newException(InputError, "'" & name & "' must be " & expected)

proc field(request: JsonNode, name: string, kind: JsonNodeKind, expected: string): JsonNode =
  ## `request[name]`; `InputError` unless it is there and of `kind`.
  result = request.optionalField(name, kind, expected)
  if result == nil:
    raise newException(InputError, "'" & name & "' must be " & expected)

proc simId(request: JsonNode): int =
  ## The request's `simId`; `InputError` if missing or not an integer.
  request.field("simId", JInt, "an integer").getInt()

proc label(request: JsonNode): Option[string] =
  ## The request's optional `label`; `InputError` if not a string.
  let node = request.optionalField("label", JString, "a string")
  if node == nil: none(string) else: some(node.getStr())

proc trnrunArgs(request: JsonNode): seq[string] =
  ## The request's optional `trnrunArgs`; `InputError` unless TRNRun options the daemon allows.
  const expected = "an array of TRNRun options"
  let node = request.optionalField("trnrunArgs", JArray, expected)
  if node == nil:
    return @[]
  if node.elems.anyIt(it.kind != JString):
    raise newException(InputError, "'trnrunArgs' must be " & expected)
  result = node.elems.mapIt(it.getStr())
  validateTrnrunArgs(result)

proc state(request: JsonNode): SimulationState =
  ## The request's `state`; `InputError` unless a simulation state.
  const expected = "QUEUED, RUNNING or FINISHED"
  try:
    parseEnum[SimulationState](request.field("state", JString, expected).getStr())
  except ValueError:
    raise newException(InputError, "'state' must be " & expected)

proc refusal(pool: Pool, simId: int, action: string): JsonNode =
  ## The response refusing to `action` simulation `simId`, saying why.
  let simulation = pool.get(simId)
  let error =
    if simulation.isNone:
      "Unknown simId: " & $simId
    else:
      "Cannot " & action & " simulation " & $simId & ": it is " & $simulation.get().state
  %*{"ok": false, "error": error}

proc dispatch(pool: var Pool, request: JsonNode): JsonNode =
  ## Runs one parsed request against `pool` and returns its response.
  if request.kind != JObject:
    raise newException(InputError, "Request must be a JSON object")
  let cmd = request.field("cmd", JString, "a string").getStr()
  case cmd
  of "ready":
    %*{"ok": true}
  of "add":
    let simId = pool.add(
      deckFile = validateDeck(request.field("deckFile", JString, "a string").getStr()),
      trnrunArgs = request.trnrunArgs(),
      label = request.label(),
    )
    %*{"ok": true, "simId": simId}
  of "cancel":
    let simId = request.simId()
    if pool.cancel(simId): %*{"ok": true} else: pool.refusal(simId, "cancel")
  of "release":
    let simId = request.simId()
    if pool.release(simId): %*{"ok": true} else: pool.refusal(simId, "release")
  of "get":
    let simId = request.simId()
    let simulation = pool.get(simId)
    if simulation.isNone:
      pool.refusal(simId, "get")
    else:
      %*{"ok": true, "simulation": simulation.get()}
  of "list":
    %*{"ok": true, "simulations": pool.list(request.state())}
  else:
    raise newException(InputError, "Unknown cmd: " & cmd)

proc handleRequest*(pool: var Pool, line: string): string =
  ## Runs the request in `line` against `pool` and returns its one-line JSON response.
  let response =
    try:
      pool.dispatch(parseJson(line))
    except InputError, JsonParsingError:
      %*{"ok": false, "error": getCurrentExceptionMsg()}
  $response
