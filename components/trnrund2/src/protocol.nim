## Turns one client request line into one response line.
##
## A request is a JSON object with a `cmd`. Every response is a JSON object
## with `ok`; when `ok` is false it also has an `error` for humans. README.md
## lists the commands. Simulation work is delegated to `scheduler`.

import std/[json, options, sequtils, strutils]
import ./[scheduler, validate]

# --------------------------
# Request fields
# --------------------------

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
  return request.field("simId", JInt, "an integer").getInt()

proc label(request: JsonNode): Option[string] =
  ## The request's optional `label`; `InputError` if not a string.
  let node = request.optionalField("label", JString, "a string")
  return if node == nil: none(string) else: some(node.getStr())

proc trnrunArgs(request: JsonNode): seq[string] =
  ## The request's optional `trnrunArgs`; `InputError` unless TRNRun options the daemon allows.
  const expected = "an array of TRNRun options"
  let node = request.optionalField("trnrunArgs", JArray, expected)
  if node == nil:
    return @[]
  if node.getElems().anyIt(it.kind != JString):
    raise newException(InputError, "'trnrunArgs' must be " & expected)
  result = node.getElems().mapIt(it.getStr())
  validateTrnrunArgs(result)

proc state(request: JsonNode): SimulationState =
  ## The request's `state`; `InputError` unless a simulation state.
  const expected = "QUEUED, RUNNING or FINISHED"
  let state =
    try:
      parseEnum[SimulationState](request.field("state", JString, expected).getStr())
    except ValueError:
      raise newException(InputError, "'state' must be " & expected)
  return state

proc withLogs(request: JsonNode): bool =
  ## The request's optional `withLogs`, false when missing; `InputError` if not a boolean.
  let node = request.optionalField("withLogs", JBool, "true or false")
  return node != nil and node.getBool()

# --------------------------
# Commands
# --------------------------
proc refusal(scheduler: Scheduler, simId: int, action: string): JsonNode =
  ## The response refusing to `action` simulation `simId`, saying why.
  let error =
    if simId notin scheduler:
      "Unknown simId: " & $simId
    else:
      "Cannot " & action & " simulation " & $simId & ": it is " & $scheduler[simId].state
  return %*{"ok": false, "error": error}

proc addCmd(scheduler: var Scheduler, request: JsonNode): JsonNode =
  ## Answers `add`: queues the requested simulation and returns its simId.
  let simId = scheduler.add(
    deckFile = validateDeck(request.field("deckFile", JString, "a string").getStr()),
    trnrunArgs = request.trnrunArgs(),
    label = request.label(),
  )
  return %*{"ok": true, "simId": simId}

proc cancelCmd(scheduler: var Scheduler, request: JsonNode): JsonNode =
  ## Answers `cancel`: cancels the simulation, or says why it cannot.
  let simId = request.simId()
  let cancelled =
    try:
      scheduler.cancel(simId)
    except OSError as error:
      return %*{"ok": false, "error": "Cannot cancel simulation " & $simId & ": " & error.msg}
  return if cancelled: %*{"ok": true} else: scheduler.refusal(simId, "cancel")

proc releaseCmd(scheduler: var Scheduler, request: JsonNode): JsonNode =
  ## Answers `release`: forgets the finished simulation, or says why it cannot.
  let simId = request.simId()
  return if scheduler.release(simId): %*{"ok": true} else: scheduler.refusal(simId, "release")

proc getCmd(scheduler: Scheduler, request: JsonNode): JsonNode =
  ## Answers `get`: returns the simulation, or says it is unknown.
  let simId = request.simId()
  return if simId in scheduler: %*{"ok": true, "simulation": scheduler[simId]} else: scheduler.refusal(simId, "get")

proc toJsonWithoutLogs(simulation: Simulation): JsonNode =
  ## `%simulation` without its `logs` key, never serializing the logs.
  result = newJObject()
  for name, value in simulation.fieldPairs:
    when name != "logs":
      result[name] = %value

proc listCmd(scheduler: Scheduler, request: JsonNode): JsonNode =
  ## Answers `list`: returns the simulations in the requested state, without `logs` unless `withLogs`.
  let
    state = request.state()
    withLogs = request.withLogs()
  var simulations = newJArray()
  for simId in scheduler.list(state):
    # Indexed in place: `scheduler[simId]` is borrowed, so no simulation is copied.
    simulations.add(if withLogs: %scheduler[simId] else: scheduler[simId].toJsonWithoutLogs())
  return %*{"ok": true, "simulations": simulations}

proc dispatch(scheduler: var Scheduler, request: JsonNode): JsonNode =
  ## Routes one parsed request to its command and returns the response.
  if request.kind != JObject:
    raise newException(InputError, "Request must be a JSON object")
  let cmd = request.field("cmd", JString, "a string").getStr()
  case cmd
  of "ready": return %*{"ok": true}
  of "add": return scheduler.addCmd(request)
  of "cancel": return scheduler.cancelCmd(request)
  of "release": return scheduler.releaseCmd(request)
  of "get": return scheduler.getCmd(request)
  of "list": return scheduler.listCmd(request)
  else: raise newException(InputError, "Unknown cmd: " & cmd)

proc handleRequest*(scheduler: var Scheduler, line: string): string =
  ## Runs the request in `line` against `scheduler` and returns its one-line JSON response.
  ##
  ## A request the client got wrong, such as bad JSON, an unknown `cmd`, a
  ## missing field or a deck that does not exist, is answered with
  ## `{"ok":false,"error":...}` rather than raised. So is a `cancel` whose
  ## TRNRun cannot be killed. Any other exception is a daemon fault and
  ## propagates.
  let response =
    try:
      scheduler.dispatch(parseJson(line))
    except InputError, JsonParsingError:
      %*{"ok": false, "error": getCurrentExceptionMsg()}
  return $response
