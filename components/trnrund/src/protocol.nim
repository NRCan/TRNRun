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
## add        runId, deckFile, trnrunArgs?
## cancel     runId
## shutdown                                           see below
## ========== ======================================= ======================
##
## A successful `add` replies with exactly {"ok":true} after saving the run;
## all lifecycle states are read from SQLite, never from the acknowledgement.
## Rejected adds reply with {"ok":false,"error":...}. `trnrunArgs` are TRNRun
## options, rejected at once if TRNRun would refuse one; see `validate`.
##
## `cancel` replies {"ok":true} once the cancellation is recorded. A queued
## run is already FINISHED and CANCELLED by then; a dispatched one becomes so
## once its TRNRun is killed. A finished run is left unchanged, so a run that
## finishes just before its cancel arrives keeps its real outcome. Only an
## unknown runId is rejected.
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
from db_connector/db_common import DbError
import ./scheduler

proc requireField(request: JsonNode, name: string): JsonNode =
  ## Returns `request[name]`; `ValueError` if it is missing.
  if name notin request:
    raise newException(ValueError, "Missing field: " & name)
  request[name]

proc handleAdd(scheduler: Scheduler, request: JsonNode) =
  ## Validates and saves a simulation before acknowledging it.
  let
    runId = request.requireField("runId").to(string)
    deckFile = request.requireField("deckFile").to(string)
    trnrunArgs =
      if "trnrunArgs" in request: request["trnrunArgs"].to(seq[string]) else: @[]
  discard scheduler.add(runId, deckFile, trnrunArgs)

proc handleCancel(scheduler: Scheduler, request: JsonNode) =
  ## Records the cancellation of a simulation before acknowledging it.
  scheduler.cancel(request.requireField("runId").to(string))

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
  ## failure but a `DbError` becomes an `ok: false` reply.
  result = (reply: "", shutdown: false)
  var reply = %*{"ok": true}
  try:
    let request = parseRequest(line)
    let cmd = request.requireField("cmd").to(string)
    case cmd
    of "ready": reply["databasePath"] = %scheduler.databasePath
    of "add": scheduler.handleAdd(request)
    of "cancel": scheduler.handleCancel(request)
    of "shutdown": result.shutdown = true
    else: raise newException(ValueError, "Unknown cmd: " & cmd)
  except DbError:
    raise
  except CatchableError as error:
    reply = %*{"ok": false, "error": error.msg}
  result.reply = $reply
