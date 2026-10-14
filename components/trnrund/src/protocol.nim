## Serves client requests, one JSON object per line in each direction.
##
## Every request gets exactly one reply carrying `ok`, in request order. A
## request may carry an `id`, any JSON value, which its reply repeats. A
## rejected request gets `error` instead of the command's result. Database
## failures are not replies: they raise and end the daemon, since
## acknowledging a run that was not saved would lose it.
##
## ========== ======================================= =============================
## cmd        request fields                          reply fields
## ========== ======================================= =============================
## ready                                              databasePath, sessionId,
##                                                    revision, logId
## subscribe                                          revision
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
## After `subscribe`, the daemon also writes `{"event":"changed","revision":N}`
## after each batch of changes it saves, so a client can block on stdout
## instead of polling the database. Replies have `ok` and notifications
## `event`. A subscribed client must keep reading stdout: the daemon waits for
## room in the pipe. Its stdout ends only after its final changes are saved.
##
## `cancel` replies once the cancellation is recorded. A queued run is already
## FINISHED and CANCELLED by then; a running one becomes so once its TRNRun is
## killed. A finished run is left unchanged. Only an unknown runId is rejected.
##
## `shutdown` replies at once, finishes queued runs as CANCELLED without
## starting them, and, with `cancelRunning`, kills running ones. The daemon
## exits once nothing runs. Meanwhile `cancel` and `shutdown` are still
## served, and `add` is rejected. Closing stdin exits at once, saving every
## unfinished run as interrupted.

import std/[json, options]
from db_connector/db_common import DbError
import ./database
import ./messages
import ./scheduler

type
  Client* = object
    ## What the daemon knows about its one client.
    subscribed*: bool
    notified*: int ## Revision of the latest notification sent.

  Output* = proc(lines: seq[string]): bool {.closure.}
    ## Writes reply and notification lines; false once the client is gone.

proc requireField(request: JsonNode, name: string): JsonNode =
  ## Returns `request[name]`; `ValueError` if it is missing.
  if name notin request:
    raise newException(ValueError, "Missing field: " & name)
  request[name]

proc getString(node: JsonNode, name: string): string =
  ## The string in `node`; `ValueError` if it holds another kind.
  if node.kind != JString:
    raise newException(ValueError, "'" & name & "' must be a string")
  node.getStr()

proc optionalField(request: JsonNode, name: string): JsonNode =
  ## `request[name]`, or nil when it is missing or null.
  result = request.getOrDefault(name)
  if result != nil and result.kind == JNull:
    result = nil

proc handleReady(scheduler: Scheduler, reply: JsonNode) =
  ## Reports the database and session a client reads from.
  reply["databasePath"] = %scheduler.databasePath
  reply["sessionId"] = %scheduler.database.sessionId
  reply["revision"] = %scheduler.database.savedRevision
  reply["logId"] = %scheduler.database.lastLogId

proc handleSubscribe(scheduler: Scheduler, client: var Client, reply: JsonNode) =
  ## Starts change notifications from the latest saved revision.
  client.subscribed = true
  client.notified = scheduler.database.savedRevision
  reply["revision"] = %client.notified

proc handleAdd(scheduler: Scheduler, request, reply: JsonNode) =
  ## Validates and saves a simulation, replying with its new runId.
  let
    deckFile = request.requireField("deckFile").getString("deckFile")
    args = request.optionalField("trnrunArgs")
    trnrunArgs = if args == nil: newSeq[string]() else: args.to(seq[string])
    labelNode = request.optionalField("label")
    label = if labelNode == nil: none(string) else: some(labelNode.getString("label"))
  reply["runId"] = %scheduler.add(deckFile, trnrunArgs, label)

proc handleCancel(scheduler: Scheduler, request: JsonNode) =
  ## Records the cancellation of a simulation before acknowledging it.
  let runId = request.requireField("runId")
  if runId.kind != JInt:
    raise newException(ValueError, "'runId' must be an integer")
  scheduler.cancel(runId.getInt())

proc handleShutdown(scheduler: Scheduler, request: JsonNode) =
  ## Starts shutting down, optionally killing running runs.
  let cancelRunning = request.optionalField("cancelRunning")
  if cancelRunning != nil and cancelRunning.kind != JBool:
    raise newException(ValueError, "'cancelRunning' must be true or false")
  scheduler.requestShutdown(cancelRunning != nil and cancelRunning.getBool())

proc parseRequest(line: string): JsonNode =
  ## Parses one request line, which must hold a JSON object.
  result = parseJson(line)
  if result.kind != JObject:
    raise newException(ValueError, "Request must be a JSON object")

proc handleRequest*(scheduler: Scheduler, client: var Client, line: string): string =
  ## Runs one request line and returns its reply line.
  ##
  ## Any failure but a `DbError` becomes an `ok: false` reply.
  var
    id: JsonNode = nil
    fields = newJObject()
    ok = true
  try:
    let request = parseRequest(line)
    id = request.getOrDefault("id")
    let cmd = request.requireField("cmd").getString("cmd")
    case cmd
    of "ready": scheduler.handleReady(fields)
    of "subscribe": scheduler.handleSubscribe(client, fields)
    of "add": scheduler.handleAdd(request, fields)
    of "cancel": scheduler.handleCancel(request)
    of "shutdown": scheduler.handleShutdown(request)
    else: raise newException(ValueError, "Unknown cmd: " & cmd)
  except DbError:
    raise
  except CatchableError as error:
    ok = false
    fields = %*{"error": error.msg}
  let reply = newJObject()
  if id != nil:
    reply["id"] = id
  reply["ok"] = %ok
  for key, value in fields:
    reply[key] = value
  $reply

proc notifyChanges(scheduler: Scheduler, client: var Client, lines: var seq[string]) =
  ## Adds a notification if a subscribed client has not seen the latest
  ## saved revision.
  if client.subscribed:
    let revision = scheduler.database.savedRevision
    if revision > client.notified:
      client.notified = revision
      lines.add($(%*{"event": "changed", "revision": revision}))

proc serve*(scheduler: Scheduler, output: Output) =
  ## Serves the client until a shutdown completes or the client leaves, then
  ## closes or abandons the scheduler.
  ##
  ## Each batch of messages is applied in one transaction, then its replies
  ## are written, followed by one notification for a subscribed client.
  var client = Client()
  while true:
    let messages = scheduler.receive()
    var
      lines: seq[string] = @[]
      closed = false
    scheduler.atomically:
      for message in messages:
        case message.kind
        of mkRequest: lines.add(scheduler.handleRequest(client, message.line))
        of mkClosed: closed = true
        of mkOutput, mkExited: scheduler.apply(message)
    scheduler.notifyChanges(client, lines)
    if lines.len > 0 and not output(lines):
      closed = true

    if closed:
      scheduler.abandon()
      return
    if scheduler.isDone:
      scheduler.close()
      return
