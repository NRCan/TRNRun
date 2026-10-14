## Serves client requests, one JSON object per line in each direction.
##
## Every request gets exactly one reply carrying `ok`, in request order. A
## request may carry an `id`, any JSON value, which its reply repeats. A
## rejected request gets `error` instead of the command's result. Daemon
## faults, such as database failures, are not replies: they raise and end the
## daemon, since acknowledging a run that was not saved would lose it.
##
## ========== ======================================= =============================
## cmd        request fields                          reply fields
## ========== ======================================= =============================
## ready                                              databasePath, sessionId,
##                                                    revision, logId
## add        deckFile, trnrunArgs?, label?           runId
## cancel     runId
## shutdown   cancelRunning?
## ========== ======================================= =============================
##
## The daemon assigns each run its `runId`, an integer never reused in the
## database. `ready` reports the session this daemon records on its runs, and
## the latest `revision` and `logId`: a client reading only later changes
## starts from them. `trnrunArgs` are TRNRun options, rejected at once if
## TRNRun would refuse one; see `validate`.
##
## After each batch of changes it saves, the daemon also writes
## `{"event":"changed","revision":N}`, so a client can block on stdout instead
## of polling the database. Replies have `ok` and notifications `event`;
## clients skip lines they do not need. Notifications never hold the daemon
## up: a separate thread writes stdout and merges the notifications a client
## has not read yet into one, see `writer`.
##
## `cancel` replies once the cancellation is recorded. A queued run is already
## FINISHED and CANCELLED by then; a running one becomes so once its TRNRun is
## killed. A finished run is left unchanged. Only an unknown runId is rejected.
##
## `shutdown` replies at once, finishes queued runs as CANCELLED without
## starting them, and, with `cancelRunning`, kills running ones. The daemon
## exits once nothing runs. Meanwhile `cancel` and `shutdown` are still
## served, and `add` is rejected. Closing stdin exits at once, saving every
## unfinished run as interrupted. Stdout ends only after the final changes are
## saved. However the daemon exits, a client that does not read gets at most
## `ExitGraceMs` to take what is left to write.

import std/[json, options, sequtils]
import ./database
import ./messages
import ./scheduler
import ./writer

export WriteLines

const ExitGraceMs = 1_000
  ## How long a daemon about to exit still writes to a client that may not be reading.

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
  reply["sessionId"] = %scheduler.database.sessionId
  reply["revision"] = %scheduler.database.savedRevision
  reply["logId"] = %scheduler.database.lastLogId

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
  ## Runs one request line and returns its reply line.
  ##
  ## A request that is not valid JSON or that the scheduler rejects becomes an
  ## `ok: false` reply. Anything else, such as a `DbError`, is a daemon fault
  ## and raises.
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

proc serve*(scheduler: Scheduler, write: WriteLines) =
  ## Serves the client until a shutdown completes or the client leaves, then
  ## closes or abandons the scheduler.
  ##
  ## Each batch of messages is applied in one transaction. Its replies and the
  ## revision it saved then go to the writer thread, which writes them with
  ## `write` without holding up the next batch. A failed write ends serving
  ## like a closed input. Returns once everything sent is written, or after
  ## `ExitGraceMs` if the client is not reading.
  var writer = Writer()
  writer.start(write, scheduler.requestInbox, scheduler.database.savedRevision)
  defer: writer.stop(ExitGraceMs)
  while true:
    let messages = scheduler.receive()
    var
      replies: seq[string] = @[]
      closed = false
    scheduler.atomically:
      for message in messages:
        case message.kind
        of mkRequest: replies.add(scheduler.handleRequest(message.line))
        of mkClosed: closed = true
        of mkOutput, mkExited: scheduler.apply(message)
    writer.send(replies, scheduler.database.savedRevision)

    if closed:
      scheduler.abandon()
      return
    if scheduler.isDone:
      scheduler.close()
      return
