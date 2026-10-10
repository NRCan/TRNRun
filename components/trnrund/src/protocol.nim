## Answers client requests, one JSON object per line in each direction.
##
## Every request gets exactly one reply carrying `ok`, in request order, so a
## client matches replies by position. A rejected request gets `error` instead
## of the command's result. Database failures are not replies: they raise and
## end the daemon, since acknowledging a run that was not saved would lose it.
##
## ========== ======================================= ======================
## cmd        request fields                          reply fields
## ========== ======================================= ======================
## ready                                              databasePath
## add        runId, deckFile, trnrunArgs?            state
## shutdown                                           see below
## ========== ======================================= ======================
##
## `add` replies at once with the run's `state`: `ACCEPTED` if a worker took
## it, else `QUEUED`.
##
## Clients read simulations from the database at `databasePath`, polling it to
## follow or wait for a run; see `database`. A simulation is done when its
## `state` is `FINISHED`, which the daemon sets after the TRNRun process exits.
## Do not use `trnrun_status = 'DONE'` or final progress instead: TRNRun can
## report them before it exits, and output may still follow. `FINISHED`
## includes failed runs; `succeeded` tells them apart.
##
## After acknowledging `shutdown`, the daemon finishes queued runs as CANCELLED
## without starting them, waits for running ones, and exits. Requests sent
## meanwhile get no reply.

import std/json
import ./[database, scheduler]

proc requireField(request: JsonNode, name: string): JsonNode =
  ## Returns `request[name]`; `ValueError` if it is missing.
  if name notin request:
    raise newException(ValueError, "Missing field: " & name)
  request[name]

proc handleAdd(scheduler: Scheduler, request: JsonNode): SimulationState =
  ## Queues a simulation and returns its state.
  let
    runId = request.requireField("runId").to(string)
    deckFile = request.requireField("deckFile").to(string)
    trnrunArgs =
      if "trnrunArgs" in request: request["trnrunArgs"].to(seq[string]) else: @[]
  scheduler.add(runId, deckFile, trnrunArgs)

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
  ## failure but a `DatabaseError` becomes an `ok: false` reply.
  result = (reply: "", shutdown: false)
  var reply = %*{"ok": true}
  try:
    let request = parseRequest(line)
    let cmd = request.requireField("cmd").to(string)
    case cmd
    of "ready": reply["databasePath"] = %scheduler.databasePath
    of "add": reply["state"] = %scheduler.handleAdd(request)
    of "shutdown": result.shutdown = true
    else: raise newException(ValueError, "Unknown cmd: " & cmd)
  except DatabaseError:
    raise
  except CatchableError as error:
    reply = %*{"ok": false, "error": error.msg}
  result.reply = $reply
