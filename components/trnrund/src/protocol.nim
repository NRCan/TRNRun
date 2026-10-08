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
## changes    since?                           revision, and simulations
##                                             changed after since; see below
## remove     runId
## shutdown                                    see below
## ========== ================================ ==============================
##
## A simulation is done when its `state` is `FINISHED`, which the daemon sets
## after the TRNRun process exits. Do not use `status.status == "DONE"` or
## final `progress` instead: TRNRun can report them before it exits, and output
## may still follow. `FINISHED` includes failed runs; `succeeded` tells them
## apart. `remove` accepts only finished runs.
##
## Every change to a simulation, including its submission, gets the next
## `revision`, a counter that only grows. `changes` returns the current
## `revision` and, in submission order, each simulation whose own `revision` is
## after `since`, 0 by default, with the log entries that arrived after `since`.
## A client passes the `revision` of its previous reply, so it receives only
## what changed, whatever the number of runs; `since` 0 returns everything. A
## `FINISHED` simulation in a reply carries its final entries, so the client
## can `remove` it afterwards. Asking again from an older `since` repeats
## changes, never skips one.
##
## Every simulation in a reply reports the 0-based `logStart` of its `logs`, so
## a client can tell where they belong, and its counters always cover every
## entry, whatever `logs` leaves out.
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

proc handleChanges(scheduler: Scheduler, request, reply: JsonNode) =
  ## Replies with the current revision and the simulations changed after `since`.
  let since = if "since" in request: request["since"].to(int) else: 0
  if since < 0:
    raise newException(ValueError, "since must not be negative: " & $since)
  var simulations = newJArray()
  for simulation in scheduler:
    if simulation.revision > since:
      simulations.add(simulation.toJson(simulation.logStartAfter(since)))
  reply["revision"] = %scheduler.revision
  reply["simulations"] = simulations

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
    of "changes": scheduler.handleChanges(request, reply)
    of "remove": scheduler.handleRemove(request)
    of "shutdown": result.shutdown = true
    else: raise newException(ValueError, "Unknown cmd: " & cmd)
  except CatchableError as error:
    reply = %*{"ok": false, "error": error.msg}
  result.reply = $reply
