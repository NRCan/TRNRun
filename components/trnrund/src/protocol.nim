## Answers client requests, one JSON object per line in each direction.
##
## README.md specifies the protocol for clients: the commands, their fields,
## and the notifications. This module turns each request line into its reply
## line, and the scheduler does the work.
##
## Every request gets exactly one reply carrying `ok`, which repeats the
## request's `id`, if any. A rejected request, such as malformed JSON or
## invalid input, gets `ok: false` and an `error`. Daemon faults, such as
## database failures, are not replies: they raise and end the daemon, since
## acknowledging a run that was not saved would lose it.

import std/[json, options, sequtils]
import ./scheduler

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

proc handleReady(scheduler: Scheduler, reply: JsonNode) =
  ## Reports the database and session a client reads from.
  reply["databasePath"] = %scheduler.databasePath
  reply["sessionId"] = %scheduler.sessionId
  reply["revision"] = %scheduler.savedRevision
  reply["logId"] = %scheduler.lastLogId

proc handleAdd(scheduler: Scheduler, request, reply: JsonNode) =
  ## Validates and saves a simulation, replying with its new runId.
  let
    deckFile = request.field("deckFile", string)
    trnrunArgs = request.optionalField("trnrunArgs", seq[string]).get(@[])
    label = request.optionalField("label", string)
  reply["runId"] = %scheduler.add(deckFile, trnrunArgs, label)

proc handleCancel(scheduler: Scheduler, request: JsonNode) =
  ## Records the cancellation of a simulation before acknowledging it.
  scheduler.cancel(request.field("runId", int))

proc handleShutdown(scheduler: Scheduler, request: JsonNode) =
  ## Starts shutting down, optionally killing running runs.
  scheduler.requestShutdown(request.optionalField("cancelRunning", bool).get(false))

proc handleRequest*(scheduler: Scheduler, line: string): string =
  ## Runs one request line and returns its reply line; a daemon fault, such as a `DbError`, raises.
  var
    id: JsonNode = nil
    fields = newJObject()
    ok = true
  try:
    let request = parseRequest(line)
    id = request.getOrDefault("id")
    let cmd = request.field("cmd", string)
    case cmd
    of "ready": scheduler.handleReady(fields)
    of "add": scheduler.handleAdd(request, fields)
    of "cancel": scheduler.handleCancel(request)
    of "shutdown": scheduler.handleShutdown(request)
    else: raise newException(InputError, "Unknown cmd: " & cmd)
  except InputError, JsonParsingError:
    ok = false
    fields = %*{"error": getCurrentExceptionMsg()}
  let reply = newJObject()
  if id != nil:
    reply["id"] = id
  reply["ok"] = %ok
  for key, value in fields:
    reply[key] = value
  $reply
