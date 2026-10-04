## Answers client requests, one JSON object per line in each direction.
##
## Every request gets exactly one reply carrying `ok`, in request order, so a
## client matches replies by position. A failed request gets `error` instead of
## the command's result.
##
## ========== ================================ ==============================
## cmd        request fields                   reply fields
## ========== ================================ ==============================
## add        runId, deckFile, trnrunArgs?
## snapshot   runId                            simulation, without logs
## snapshots  runIds?                          simulations, without logs;
##                                             all in submission order by
##                                             default
## logs       runId, start?, stop?             logs, entries [start, stop),
##                                             all by default; see below
## remove     runId
## collect    runId                            simulation, without logs, and
##                                             logs; then removes it
## shutdown                                    see below
## ========== ================================ ==============================
##
## A simulation is done when its `state` is `FINISHED`, which the daemon sets
## after the TRNRun process exits. Do not use `status.status == "DONE"` or
## final `progress` instead: TRNRun can report them before it exits, and output
## may still follow. `FINISHED` includes failed runs; `succeeded` tells them
## apart. Read `logs` before `remove`, which accepts only finished runs, or
## `collect` to do both at once.
##
## `logs` bounds work like a Python slice: 0-based, `stop` exclusive, negative
## values count from the end, and out-of-range values are clamped. A client
## polling a running simulation passes the count it already holds as `start`.
##
## After acknowledging `shutdown`, the daemon finishes queued runs as CANCELLED
## without starting them, waits for running ones, and exits. Requests sent
## meanwhile get no reply.

import std/json
import ./scheduler

proc requireField(request: JsonNode, name: string): JsonNode =
  ## Returns `request[name]`; `ValueError` if it is missing.
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
  reply["simulation"] = %scheduler[runId]

proc handleSnapshots(scheduler: Scheduler, request, reply: JsonNode) =
  ## Replies with the listed simulations, or all of them, without their logs.
  var simulations = newJArray()
  if "runIds" in request:
    for runId in request["runIds"].to(seq[string]):
      simulations.add(%scheduler[runId])
  else:
    for simulation in scheduler:
      simulations.add(%simulation)
  reply["simulations"] = simulations

proc sliceBound(request: JsonNode, name: string, default, count: int): int =
  ## Resolves an optional Python-style slice bound to an index in `0..count`.
  result = if name in request: request[name].to(int) else: default
  if result < 0:
    result += count
  result = result.clamp(0, count)

proc handleLogs(scheduler: Scheduler, request, reply: JsonNode) =
  ## Replies with the log entries in `[start, stop)`, every entry by default.
  let runId = request.requireField("runId").to(string)
  let count = scheduler[runId].logs.len
  let
    start = request.sliceBound("start", 0, count)
    stop = request.sliceBound("stop", count, count)
  reply["logs"] = %scheduler[runId].logs[start ..< max(start, stop)]

proc handleRemove(scheduler: Scheduler, request: JsonNode) =
  ## Forgets a finished simulation so its runId can be reused.
  let runId = request.requireField("runId").to(string)
  scheduler.remove(runId)

proc handleCollect(scheduler: Scheduler, request, reply: JsonNode) =
  ## Replies with a finished simulation and all its logs, then forgets it.
  let runId = request.requireField("runId").to(string)
  if scheduler[runId].state != ssFinished:
    raise newException(ValueError, "Simulation has not finished: " & runId)
  reply["simulation"] = %scheduler[runId]
  reply["logs"] = %scheduler[runId].logs
  scheduler.remove(runId)

proc parseRequest(line: string): JsonNode =
  ## Parses one request line, which must hold a JSON object.
  result = parseJson(line)
  if result.kind != JObject:
    raise newException(ValueError, "Request must be a JSON object")

proc handleRequest*(
    scheduler: Scheduler, line: string
): tuple[reply: string, shutdown: bool] =
  ## Runs one request line and returns its reply line.
  ##
  ## `shutdown` is true when the client asked the daemon to shut down. Any
  ## failure becomes an `ok: false` reply instead of an exception.
  result = (reply: "", shutdown: false)
  var reply = %*{"ok": true}
  try:
    let request = parseRequest(line)
    let cmd = request.requireField("cmd").to(string)
    case cmd
    of "add": scheduler.handleAdd(request)
    of "snapshot": scheduler.handleSnapshot(request, reply)
    of "snapshots": scheduler.handleSnapshots(request, reply)
    of "logs": scheduler.handleLogs(request, reply)
    of "remove": scheduler.handleRemove(request)
    of "collect": scheduler.handleCollect(request, reply)
    of "shutdown": result.shutdown = true
    else: raise newException(ValueError, "Unknown cmd: " & cmd)
  except CatchableError as error:
    reply = %*{"ok": false, "error": error.msg}
  result.reply = $reply
