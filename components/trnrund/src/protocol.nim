## Answers client requests, one JSON object per line in each direction.
##
## README.md specifies the protocol for clients: the commands, their fields,
## and the run and log objects. This module turns each request line into its
## reply line, and the scheduler does the work.
##
## Every request gets exactly one reply carrying `ok`, which repeats the
## request's `id`, if any. A rejected request, such as malformed JSON or
## invalid input, gets `ok: false` and an `error`. An `add` that waits for its
## run to start or finish gets no reply here: the scheduler holds it until the
## run gets there, see `takeReplies`. Replies are written straight to a string.

import std/[json, options, sequtils]
import ./scheduler

const
  NimblePkgVersion* {.strdefine.} = "unknown"
  ProtocolVersion* = 2 ## Bump whenever a command, field, or object changes what clients read.

proc parseField(node: JsonNode, name: string, _: typedesc[string]): string =
  ## The string in field `name`; `InputError` if it holds another kind.
  if node.kind != JString:
    raise newException(InputError, "'" & name & "' must be a string")
  node.getStr()

proc parseField(node: JsonNode, name: string, _: typedesc[int]): int =
  ## The integer in field `name`; `InputError` if it holds another kind.
  if node.kind != JInt:
    raise newException(InputError, "'" & name & "' must be an integer")
  node.getInt()

proc parseField(node: JsonNode, name: string, _: typedesc[bool]): bool =
  ## The boolean in field `name`; `InputError` if it holds another kind.
  if node.kind != JBool:
    raise newException(InputError, "'" & name & "' must be true or false")
  node.getBool()

proc parseField(
    node: JsonNode, name: string, _: typedesc[SimulationState]
): SimulationState =
  ## The run state named in field `name`; `InputError` if it names none.
  for state in SimulationState:
    if node.kind == JString and node.getStr() == $state:
      return state
  raise newException(InputError, "'" & name & "' must be QUEUED, RUNNING or FINISHED")

proc parseField(node: JsonNode, name: string, _: typedesc[seq[string]]): seq[string] =
  ## The strings in array field `name`; `InputError` if it holds anything else.
  if node.kind != JArray or node.elems.anyIt(it.kind != JString):
    raise newException(InputError, "'" & name & "' must be an array of strings")
  node.elems.mapIt(it.getStr())

proc field[T](request: JsonNode, name: string, _: typedesc[T]): T =
  ## `request[name]` as a `T`; `InputError` if it is missing or of another type.
  if name notin request:
    raise newException(InputError, "Missing field: " & name)
  request[name].parseField(name, T)

proc optionalField[T](request: JsonNode, name: string, _: typedesc[T]): Option[T] =
  ## `request[name]` as a `T`, or none when it is missing or null.
  let node = request.getOrDefault(name)
  if node == nil or node.kind == JNull: none(T) else: some(node.parseField(name, T))

proc parseRequest(line: string): JsonNode =
  ## Parses one request line, which must hold a JSON object.
  result = parseJson(line)
  if result.kind != JObject:
    raise newException(InputError, "Request must be a JSON object")

proc addRun(reply: var string, scheduler: Scheduler, runId: int) =
  ## Appends `,"run":` and the run `runId`; `InputError` if it is unknown or released.
  if runId notin scheduler.store:
    raise newException(InputError, "Unknown runId: " & $runId)
  reply.add(",\"run\":")
  reply.addJson(scheduler.store[runId])

proc handleReady(scheduler: Scheduler, reply: var string) =
  ## Reports the protocol and daemon versions and the concurrency limit.
  reply.add(",\"protocolVersion\":" & $ProtocolVersion)
  reply.add(",\"version\":")
  NimblePkgVersion.escapeJson(reply)
  reply.add(",\"maxConcurrent\":" & $scheduler.maxConcurrent)

proc handleAdd(scheduler: Scheduler, request: JsonNode, id: string, reply: var string): bool =
  ## Validates and stores a simulation, replying with its new runId and run;
  ## false when the reply waits for the run to reach `waitFor`.
  let
    deckFile = request.field("deckFile", string)
    trnrunArgs = request.optionalField("trnrunArgs", seq[string]).get(@[])
    label = request.optionalField("label", string)
    waitFor = request.optionalField("waitFor", SimulationState).get(ssQueued)
  if waitFor > ssQueued and id.len == 0:
    raise newException(InputError, "'waitFor' needs an 'id' to match its reply")
  let runId = scheduler.add(deckFile, trnrunArgs, label, waitFor, id)
  if waitFor > ssQueued:
    return false
  reply.add(",\"runId\":" & $runId)
  reply.addRun(scheduler, runId)
  true

proc handleGet(scheduler: Scheduler, request: JsonNode, reply: var string) =
  ## Replies with one run and all its logs.
  reply.addRun(scheduler, request.field("runId", int))

proc handleRelease(scheduler: Scheduler, request: JsonNode) =
  ## Deletes a finished run the client has saved.
  scheduler.release(request.field("runId", int))

proc handleCancel(scheduler: Scheduler, request: JsonNode) =
  ## Records the cancellation of a simulation before acknowledging it.
  scheduler.cancel(request.field("runId", int))

proc handleShutdown(scheduler: Scheduler, request: JsonNode) =
  ## Stops new work, optionally killing running runs; requests are still answered.
  scheduler.requestShutdown(request.optionalField("cancelRunning", bool).get(false))

proc handleRequest*(scheduler: Scheduler, line: string): string =
  ## Runs one request line and returns its reply line, or "" for an `add` that
  ## waits for its run; a daemon fault raises.
  var
    id = "" ## The request's `id` as JSON; empty without one.
    fields = "" ## The reply's fields after `ok`, each with its leading comma.
    ok = true
  try:
    let request = parseRequest(line)
    if "id" in request:
      id = $request["id"]
    let cmd = request.field("cmd", string)
    case cmd
    of "ready": scheduler.handleReady(fields)
    of "add":
      if not scheduler.handleAdd(request, id, fields):
        return ""
    of "get": scheduler.handleGet(request, fields)
    of "release": scheduler.handleRelease(request)
    of "cancel": scheduler.handleCancel(request)
    of "shutdown": scheduler.handleShutdown(request)
    else: raise newException(InputError, "Unknown cmd: " & cmd)
  except InputError, JsonParsingError:
    ok = false
    fields = ",\"error\":"
    getCurrentExceptionMsg().escapeJson(fields)
  result = "{"
  if id.len > 0:
    result.add("\"id\":" & id & ",")
  result.add("\"ok\":" & $ok)
  result.add(fields)
  result.add('}')
