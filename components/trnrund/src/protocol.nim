## Answers client requests, one JSON object per line in each direction.
##
## Every request gets exactly one reply carrying the request `id` and `ok`.
## A failed request gets `error` instead of the command's result.
##
## ========== ================================ ==============================
## cmd        request fields                   reply fields
## ========== ================================ ==============================
## add        runId, deckFile, trnrunArgs?
## snapshot   runId                            simulation, without logs
## logs       runId                            logs, every entry so far
## remove     runId
## shutdown                                    see below
## ========== ================================ ==============================
##
## After acknowledging `shutdown`, the daemon finishes queued runs as CANCELLED
## without starting them, waits for running ones, and exits. Requests sent
## meanwhile get no reply.

import std/json
import ./scheduler

proc requireField(request: JsonNode, name: string): JsonNode =
  if name notin request:
    raise newException(ValueError, "Missing field: " & name)
  request[name]

proc handleAdd(scheduler: Scheduler, request: JsonNode) =
  ## Queues a simulation, dispatching it at once if a worker is free.
  let
    runId = request.requireField("runId").to(string)
    deckFile = request.requireField("deckFile").to(string)
    trnrunArgs =
      if "trnrunArgs" in request: request["trnrunArgs"].to(seq[string]) else: @[]
  scheduler.add(runId, deckFile, trnrunArgs)

proc handleSnapshot(scheduler: Scheduler, request, reply: JsonNode) =
  ## Replies with the simulation's current state, without its logs.
  let runId = request.requireField("runId").to(string)
  reply["simulation"] = scheduler[runId].toJson()

proc handleLogs(scheduler: Scheduler, request, reply: JsonNode) =
  ## Replies with every log entry so far.
  let runId = request.requireField("runId").to(string)
  reply["logs"] = %scheduler[runId].logs

proc handleRemove(scheduler: Scheduler, request: JsonNode) =
  ## Forgets a finished simulation so its runId can be reused.
  let runId = request.requireField("runId").to(string)
  scheduler.remove(runId)

proc parseRequest(line: string): JsonNode =
  ## Parses one request line, which must hold a JSON object.
  result = parseJson(line)
  if result.kind != JObject:
    raise newException(ValueError, "Request must be a JSON object")

proc handleRequest*(
    scheduler: Scheduler, line: string
): tuple[reply: string, shutdown: bool] =
  ## Runs one request line. Returns its reply line and whether the client asked
  ## the daemon to shut down.
  result = (reply: "", shutdown: false)
  var reply = %*{"id": nil, "ok": true}
  try:
    let request = parseRequest(line)
    if "id" in request:
      reply["id"] = request["id"]

    let cmd = request.requireField("cmd").to(string)
    case cmd
    of "add": scheduler.handleAdd(request)
    of "snapshot": scheduler.handleSnapshot(request, reply)
    of "logs": scheduler.handleLogs(request, reply)
    of "remove": scheduler.handleRemove(request)
    of "shutdown": result.shutdown = true
    else: raise newException(ValueError, "Unknown cmd: " & cmd)
  except CatchableError as error:
    reply = %*{"id": reply["id"], "ok": false, "error": error.msg}
  result.reply = $reply
