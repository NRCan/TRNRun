## Turns one client request line into one response line.
##
## A request is a JSON object with a `cmd`. Every response is a JSON object
## with `ok`; when `ok` is false it also has an `error` for humans. README.md
## lists the commands. Simulation work is delegated to `pool`.

import std/[json, options, sequtils, strutils]
import ./[pool, validate]

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

proc field(
    request: JsonNode,
    name: string,
    kind: JsonNodeKind,
    expected: string,
): JsonNode =
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

proc withLogs(request: JsonNode): bool =
  ## The request's optional `withLogs`, true when missing; `InputError` if not a boolean.
  let node = request.optionalField("withLogs", JBool, "true or false")
  node == nil or node.getBool()

proc listJson(pool: Pool, state: SimulationState, withLogs: bool): JsonNode =
  ## The simulations `list` returns for `state`, without their `logs` key unless `withLogs`.
  result = %pool.list(state)
  if not withLogs:
    for simulation in result:
      simulation.delete("logs")

proc refusal(pool: Pool, simId: int, action: string): JsonNode =
  ## The response refusing to `action` simulation `simId`, saying why.
  let error =
    if simId notin pool:
      "Unknown simId: " & $simId
    else:
      "Cannot " & action & " simulation " & $simId & ": it is " & $pool[simId].state
  %*{"ok": false, "error": error}

proc addCmd(pool: var Pool, request: JsonNode): JsonNode =
  ## Answers `add`: queues the requested simulation and returns its simId.
  let simId = pool.add(
    deckFile = validateDeck(request.field("deckFile", JString, "a string").getStr()),
    trnrunArgs = request.trnrunArgs(),
    label = request.label(),
  )
  %*{"ok": true, "simId": simId}

proc cancelCmd(pool: var Pool, request: JsonNode): JsonNode =
  ## Answers `cancel`: cancels the simulation, or says why it cannot.
  let simId = request.simId()
  let cancelled =
    try:
      pool.cancel(simId)
    except OSError as error:
      return %*{"ok": false, "error": "Cannot cancel simulation " & $simId & ": " & error.msg}
  if cancelled: %*{"ok": true} else: pool.refusal(simId, "cancel")

proc releaseCmd(pool: var Pool, request: JsonNode): JsonNode =
  ## Answers `release`: forgets the finished simulation, or says why it cannot.
  let simId = request.simId()
  if pool.release(simId): %*{"ok": true} else: pool.refusal(simId, "release")

proc getCmd(pool: Pool, request: JsonNode): JsonNode =
  ## Answers `get`: returns the simulation, or says it is unknown.
  let simId = request.simId()
  if simId in pool: %*{"ok": true, "simulation": pool[simId]} else: pool.refusal(simId, "get")

proc listCmd(pool: Pool, request: JsonNode): JsonNode =
  ## Answers `list`: returns the simulations in the requested state.
  %*{"ok": true, "simulations": pool.listJson(request.state(), request.withLogs())}

proc dispatch(pool: var Pool, request: JsonNode): JsonNode =
  ## Routes one parsed request to its command and returns the response.
  if request.kind != JObject:
    raise newException(InputError, "Request must be a JSON object")
  let cmd = request.field("cmd", JString, "a string").getStr()
  case cmd
  of "ready": %*{"ok": true}
  of "add": pool.addCmd(request)
  of "cancel": pool.cancelCmd(request)
  of "release": pool.releaseCmd(request)
  of "get": pool.getCmd(request)
  of "list": pool.listCmd(request)
  else: raise newException(InputError, "Unknown cmd: " & cmd)

proc handleRequest*(pool: var Pool, line: string): string =
  ## Runs the request in `line` against `pool` and returns its one-line JSON response.
  ##
  ## A request the client got wrong, such as bad JSON, an unknown `cmd`, a
  ## missing field or a deck that does not exist, is answered with
  ## `{"ok":false,"error":...}` rather than raised. So is a `cancel` whose
  ## TRNRun cannot be killed. Any other exception is a daemon fault and
  ## propagates.
  let response =
    try:
      pool.dispatch(parseJson(line))
    except InputError, JsonParsingError:
      %*{"ok": false, "error": getCurrentExceptionMsg()}
  $response
