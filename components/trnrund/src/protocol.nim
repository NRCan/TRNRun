## Turns one client request line into one response line.
##
## A request is a JSON object with a `cmd`. Every response is a JSON object
## with `ok`; when `ok` is false it also has an `error` for humans. README.md
## lists the commands. Simulation work is delegated to `scheduler`.

import std/[json, options, strutils]
import ./[scheduler, validate]
from ./cli import NimblePkgVersion

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

proc trnrunOptions(request: JsonNode): JsonNode =
  ## The request's optional `trnrunOptions`, empty when missing; `InputError` unless options the daemon allows.
  result = request.optionalField("trnrunOptions", JObject, "an object of TRNRun options")
  if result == nil:
    return newJObject()
  validateTrnrunOptions(result)

proc states(request: JsonNode): set[SimulationState] =
  ## The request's optional `state`, one state or an array of them, every state when missing; `InputError` otherwise.
  let node = request.getOrDefault("state")
  if node == nil or node.kind == JNull:
    return {SimulationState.low .. SimulationState.high}
  result = {}
  for name in (if node.kind == JArray: node.getElems() else: @[node]):
    try:
      result.incl(parseEnum[SimulationState](name.getStr())) # getStr is "" for a non-string, which no state matches.
    except ValueError:
      raise newException(InputError, "'state' must be QUEUED, RUNNING or FINISHED, or an array of them")

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
    trnrunOptions = request.trnrunOptions(),
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

proc toJsonWithoutLogs(simulation: Simulation): JsonNode =
  ## `%simulation` without its `logs` key, never serializing the logs.
  result = newJObject()
  for name, value in simulation.fieldPairs:
    when name != "logs":
      result[name] = %value

proc simulationCmd(scheduler: Scheduler, request: JsonNode): JsonNode =
  ## Answers `simulation`: returns the simulation, without `logs` unless `withLogs`, or says it is unknown.
  let
    simId = request.simId()
    withLogs = request.withLogs()
  if simId notin scheduler:
    return scheduler.refusal(simId, "get")
  let simulation = if withLogs: %scheduler[simId] else: scheduler[simId].toJsonWithoutLogs()
  return %*{"ok": true, "simulation": simulation}

proc simulationsCmd(scheduler: Scheduler, request: JsonNode): JsonNode =
  ## Answers `simulations`: returns the simulations in the requested states, or all, without `logs` unless `withLogs`.
  let
    states = request.states()
    withLogs = request.withLogs()
  var simulations = newJArray()
  for simId in scheduler.list(states):
    # Indexed in place: `scheduler[simId]` is borrowed, so no simulation is copied.
    simulations.add(if withLogs: %scheduler[simId] else: scheduler[simId].toJsonWithoutLogs())
  return %*{"ok": true, "simulations": simulations}

proc allowFields(request: JsonNode, cmd: string, allowed: varargs[string]) =
  ## `InputError` if `request` has a field other than `cmd` and `allowed`, so a typo is not silently ignored.
  for name in request.keys:
    if name != "cmd" and name notin allowed:
      raise newException(InputError, "Unknown field in " & cmd & " request: '" & name & "'")

proc dispatch(scheduler: var Scheduler, request: JsonNode): JsonNode =
  ## Routes one parsed request to its command and returns the response.
  if request.kind != JObject:
    raise newException(InputError, "Request must be a JSON object")
  let cmd = request.field("cmd", JString, "a string").getStr()
  case cmd
  of "ready":
    request.allowFields(cmd)
    return %*{"ok": true, "version": NimblePkgVersion}
  of "add":
    request.allowFields(cmd, "deckFile", "label", "trnrunOptions")
    return scheduler.addCmd(request)
  of "cancel":
    request.allowFields(cmd, "simId")
    return scheduler.cancelCmd(request)
  of "release":
    request.allowFields(cmd, "simId")
    return scheduler.releaseCmd(request)
  of "simulation":
    request.allowFields(cmd, "simId", "withLogs")
    return scheduler.simulationCmd(request)
  of "simulations":
    request.allowFields(cmd, "state", "withLogs")
    return scheduler.simulationsCmd(request)
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
