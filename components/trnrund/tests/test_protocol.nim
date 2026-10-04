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

proc checkError(reply: JsonNode, error: string) =
  check reply == %*{"ok": false, "error": error}

suite "protocol":
  test "add, snapshot, logs, and remove a simulation":
    let directory = createTempDir("trnrund-protocol-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let path = directory / "first.dck"
    writeFile(path, "fast")
    try:
      check scheduler.call(%*{
        "cmd": "add", "runId": "first", "deckFile": path, "trnrunArgs": ["--test"],
      }) == %*{"ok": true}
      scheduler.shutdown() # Waits for the run; reads and remove still work.

      let reply = scheduler.call(%*{"cmd": "snapshot", "runId": "first"})
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

      let logs = scheduler.call(%*{"cmd": "logs", "runId": "first"})
      check logs["logs"].len == 1
      check logs["logs"][0]["message"] == %"Started"

      check scheduler.call(%*{"cmd": "remove", "runId": "first"}) == %*{"ok": true}
      check not scheduler.call(%*{"cmd": "snapshot", "runId": "first"})["ok"].getBool()
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "collect returns a finished simulation with its logs, then removes it":
    let directory = createTempDir("trnrund-protocol-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let path = directory / "first.dck"
    writeFile(path, "fast")
    try:
      check scheduler.call(%*{"cmd": "add", "runId": "first", "deckFile": path})["ok"].getBool()
      let beforeSnapshot = scheduler.call(%*{"cmd": "snapshot", "runId": "first"})
      let beforeLogs = scheduler.call(%*{"cmd": "logs", "runId": "first"})
      check beforeSnapshot["ok"].getBool()
      check beforeLogs["ok"].getBool()
      scheduler.call(%*{"cmd": "collect", "runId": "first"}).checkError(
        "Simulation has not finished: first"
      )
      check scheduler.call(%*{"cmd": "snapshot", "runId": "first"}) == beforeSnapshot
      check scheduler.call(%*{"cmd": "logs", "runId": "first"}) == beforeLogs
      scheduler.shutdown() # Waits for the run; collect still works.

      let reply = scheduler.call(%*{"cmd": "collect", "runId": "first"})
      check reply["ok"].getBool()
      check reply["simulation"]["state"] == %"FINISHED"
      check "logs" notin reply["simulation"]
      check reply["logs"].len == 1
      check reply["logs"][0]["message"] == %"Started"

      scheduler.call(%*{"cmd": "snapshot", "runId": "first"}).checkError(
        "Unknown runId: first"
      )
      scheduler.call(%*{"cmd": "collect", "runId": "first"}).checkError(
        "Unknown runId: first"
      )
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "snapshots returns simulations in submission or request order":
    let directory = createTempDir("trnrund-protocol-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    try:
      check scheduler.call(%*{"cmd": "snapshots"}) == %*{"ok": true, "simulations": []}
      for name in ["first", "second", "third"]:
        let path = directory / (name & ".dck")
        writeFile(path, "fast")
        check scheduler.call(%*{"cmd": "add", "runId": name, "deckFile": path})["ok"].getBool()
      scheduler.shutdown()

      proc listed(request: JsonNode): seq[string] =
        result = @[]
        let reply = scheduler.call(request)
        check reply["ok"].getBool()
        for simulation in reply["simulations"]:
          check "logs" notin simulation
          result.add(simulation["runId"].getStr())

      check listed(%*{"cmd": "snapshots"}) == @["first", "second", "third"]
      check listed(%*{"cmd": "snapshots", "runIds": ["third", "first"]}) == @["third", "first"]
      check listed(%*{"cmd": "snapshots", "runIds": []}).len == 0

      let all = scheduler.call(%*{"cmd": "snapshots"})["simulations"]
      check all[1] == scheduler.call(%*{"cmd": "snapshot", "runId": "second"})["simulation"]

      scheduler.call(%*{"cmd": "snapshots", "runIds": ["first", "x"]}).checkError(
        "Unknown runId: x"
      )
      check not scheduler.call(%*{"cmd": "snapshots", "runIds": "first"})["ok"].getBool()
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "logs slices like a Python sequence":
    let directory = createTempDir("trnrund-protocol-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let path = directory / "logs.dck"
    writeFile(path, "three-logs")
    try:
      check scheduler.call(%*{"cmd": "add", "runId": "logs", "deckFile": path})["ok"].getBool()
      scheduler.shutdown()

      proc messages(bounds: JsonNode): seq[string] =
        result = @[]
        var request = %*{"cmd": "logs", "runId": "logs"}
        for key, value in bounds:
          request[key] = value
        let reply = scheduler.call(request)
        check reply["ok"].getBool()
        for entry in reply["logs"]:
          result.add(entry["message"].getStr())

      check messages(%*{}) == @["Started", "Second", "Third"]
      check messages(%*{"start": 1}) == @["Second", "Third"]
      check messages(%*{"stop": 2}) == @["Started", "Second"]
      check messages(%*{"start": 1, "stop": 2}) == @["Second"]
      check messages(%*{"start": -1}) == @["Third"]
      check messages(%*{"stop": -1}) == @["Started", "Second"]
      check messages(%*{"start": 3}).len == 0 # Caught up: nothing new.
      check messages(%*{"start": 9, "stop": 20}).len == 0 # Clamped.
      check messages(%*{"start": -9}) == @["Started", "Second", "Third"]
      check messages(%*{"start": 2, "stop": 1}).len == 0

      let wrongType = scheduler.call(%*{"cmd": "logs", "runId": "logs", "start": "a"})
      check not wrongType["ok"].getBool()
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "every failure is a reply":
    let scheduler = newScheduler(fakeTrnrun, 1)
    try:
      scheduler.call("garbage").checkError("input(1, 7) Error: { expected")
      scheduler.call("[]").checkError("Request must be a JSON object")
      scheduler.call(%*{}).checkError("Missing field: cmd")
      scheduler.call(%*{"cmd": "nope"}).checkError("Unknown cmd: nope")
      scheduler.call(%*{"cmd": "snapshot"}).checkError("Missing field: runId")
      scheduler.call(%*{"cmd": "snapshot", "runId": "x"}).checkError("Unknown runId: x")
      let missing =
        scheduler.call(%*{"cmd": "add", "runId": "x", "deckFile": "missing.dck"})
      check not missing["ok"].getBool()
      check "id" notin missing
      let wrongType = scheduler.call(%*{"cmd": "remove", "runId": 7})
      check not wrongType["ok"].getBool()
    finally:
      scheduler.shutdown()

  test "shutdown is acknowledged and reported to the daemon":
    let scheduler = newScheduler(fakeTrnrun, 1)
    try:
      let (reply, shutdown) = scheduler.handleRequest("""{"cmd":"shutdown"}""")
      check shutdown
      check parseJson(reply) == %*{"ok": true}
    finally:
      scheduler.shutdown()
