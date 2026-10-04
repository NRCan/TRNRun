import std/[json, os, tempfiles, unittest]
import ../src/[scheduler, protocol]

let fakeTrnrun = getAppDir() / "fake_trnrun.exe"
if not fileExists(fakeTrnrun):
  quit("Compile fake_trnrun.exe beside the test executable first", 2)

proc call(scheduler: Scheduler, line: string): JsonNode =
  let (reply, shutdown) = scheduler.handleRequest(line)
  check not shutdown
  parseJson(reply)

proc call(scheduler: Scheduler, request: JsonNode): JsonNode =
  scheduler.call($request)

proc checkError(reply: JsonNode, id: JsonNode, error: string) =
  check reply == %*{"id": id, "ok": false, "error": error}

suite "protocol":
  test "add, snapshot, logs, and remove a simulation":
    let directory = createTempDir("trnrund-protocol-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let path = directory / "first.dck"
    writeFile(path, "fast")
    try:
      check scheduler.call(%*{
        "id": 1, "cmd": "add", "runId": "first", "deckFile": path,
        "trnrunArgs": ["--test"],
      }) == %*{"id": 1, "ok": true}
      scheduler.wait()

      let reply = scheduler.call(%*{"id": 2, "cmd": "snapshot", "runId": "first"})
      check reply["ok"].getBool()
      let simulation = reply["simulation"]
      check simulation["trnrunArgs"] == %*["--test"]
      check simulation["state"] == %"FINISHED"
      check simulation["status"] == %*{"status": "DONE", "message": "Completed"}
      check simulation["succeeded"] == %true
      check simulation["notices"] == %1
      check simulation["warnings"] == %0
      check simulation["fatals"] == %0
      check "logs" notin simulation

      let logs = scheduler.call(%*{"id": 3, "cmd": "logs", "runId": "first"})
      check logs["logs"].len == 1
      check logs["logs"][0]["message"] == %"Started"

      check scheduler.call(%*{"id": 4, "cmd": "remove", "runId": "first"}) ==
        %*{"id": 4, "ok": true}
      check not scheduler.call(%*{"id": 5, "cmd": "snapshot", "runId": "first"})["ok"].getBool()
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "every failure is a reply that echoes the request id":
    let scheduler = newScheduler(fakeTrnrun, 1)
    try:
      scheduler.call("garbage").checkError(newJNull(), "input(1, 7) Error: { expected")
      scheduler.call("[]").checkError(newJNull(), "Request must be a JSON object")
      scheduler.call(%*{"id": 1}).checkError(%1, "Missing field: cmd")
      scheduler.call(%*{"id": 2, "cmd": "nope"}).checkError(%2, "Unknown cmd: nope")
      scheduler.call(%*{"id": 3, "cmd": "snapshot"}).checkError(%3, "Missing field: runId")
      scheduler.call(%*{"id": 4, "cmd": "snapshot", "runId": "x"}).checkError(
        %4, "Unknown runId: x"
      )
      let missing =
        scheduler.call(%*{"id": 5, "cmd": "add", "runId": "x", "deckFile": "missing.dck"})
      check missing["id"] == %5
      check not missing["ok"].getBool()
      # A request without an id still gets a reply, with a null id.
      let wrongType = scheduler.call(%*{"cmd": "remove", "runId": 7})
      check wrongType["id"].kind == JNull
      check not wrongType["ok"].getBool()
    finally:
      scheduler.shutdown()

  test "shutdown is acknowledged and reported to the daemon":
    let scheduler = newScheduler(fakeTrnrun, 1)
    try:
      let (reply, shutdown) = scheduler.handleRequest("""{"id":9,"cmd":"shutdown"}""")
      check shutdown
      check parseJson(reply) == %*{"id": 9, "ok": true}
    finally:
      scheduler.shutdown()
