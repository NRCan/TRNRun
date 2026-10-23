import std/[json, os, unittest]

import ../src/client/protocol
import ../src/worker/pool
import ./fake_trnrun

let dir = createDeckDir()

suite "protocol":
  var pool = initPool(getAppFilename(), 1)

  proc request(line: string): JsonNode =
    ## Sends `line` to the protocol and parses its response, which must be one line.
    let response = pool.handleRequest(line)
    check '\n' notin response
    parseJson(response)

  proc request(node: JsonNode): JsonNode =
    ## Sends `node` as one request line.
    request($node)

  proc add(node: JsonNode): int =
    ## Sends the `add` request `node` and returns its simId.
    let response = request(node)
    check response["ok"].getBool()
    response["simId"].getInt()

  proc add(deckFile: string): int =
    ## Adds `deckFile` and returns its simId.
    add(%*{"cmd": "add", "deckFile": deckFile})

  proc simulation(simId: int): JsonNode =
    ## The `get` response's simulation for `simId`.
    request(%*{"cmd": "get", "simId": simId})["simulation"]

  proc rejects(response: JsonNode, error: string): bool =
    ## Whether `response` is a refusal with exactly `error`.
    response == %*{"ok": false, "error": error}

  teardown:
    pool.stop()

  test "ready answers true":
    check request("""{"cmd":"ready"}""") == %*{"ok": true}

  test "add accepts a deck with a label and TRNRun options":
    let deckFile = createDeck(dir, "wait-a.dck")
    let simId = add(%*{
      "cmd": "add",
      "deckFile": deckFile,
      "label": "first",
      "trnrunArgs": ["--pollMs:50"],
    })
    let simulation = simulation(simId)
    check simulation["simId"].getInt() == simId
    check simulation["deckFile"].getStr() == deckFile
    check simulation["label"].getStr() == "first"
    check simulation["trnrunArgs"] == %*["--pollMs:50"]
    check simulation["state"].getStr() == "RUNNING"

  test "get returns every field of the simulation":
    let simId = add(%*{"cmd": "add", "deckFile": createDeck(dir, "done-b.dck")})
    var simulation = simulation(simId)
    for _ in 1..500:
      if simulation["state"].getStr() == "FINISHED":
        break
      sleep(10)
      pool.update()
      simulation = simulation(simId)
    var fieldCount = 0
    for name, _ in default(Simulation).fieldPairs:
      check simulation.hasKey(name)
      inc fieldCount
    check simulation.len == fieldCount
    check simulation["trnrunStatus"].getStr() == "DONE"
    check simulation["succeeded"].getBool()
    check simulation["label"].kind == JNull
    check simulation["logs"][0] == %*{
      "severity": "Notice",
      "time": 0.0,
      "unitId": nil,
      "typeId": nil,
      "messageCode": nil,
      "message": "first",
      "information": nil,
    }

  test "add queues past the worker limit":
    discard add(createDeck(dir, "wait-c1.dck"))
    let queued = add(createDeck(dir, "wait-c2.dck"))
    check simulation(queued)["state"].getStr() == "QUEUED"

  test "add rejects a bad deckFile, label or trnrunArgs":
    let deckFile = createDeck(dir, "done-d.dck")
    check request(%*{"cmd": "add", "deckFile": dir / "none.dck"}).rejects(
      "Deck file not found: '" & dir / "none.dck" & "'")
    check request(%*{"cmd": "add", "deckFile": createDeck(dir, "d.txt")}).rejects(
      "Expected .dck or .trd, got: '" & dir / "d.txt" & "'")
    check request(%*{"cmd": "add"}).rejects("'deckFile' must be a string")
    check request(%*{"cmd": "add", "deckFile": 3}).rejects("'deckFile' must be a string")
    check request(%*{"cmd": "add", "deckFile": deckFile, "label": 1}).rejects(
      "'label' must be a string")
    for args in [%*"--clean:true", %*[1]]:
      check request(%*{"cmd": "add", "deckFile": deckFile, "trnrunArgs": args}).rejects(
        "'trnrunArgs' must be an array of TRNRun options")
    check request(%*{"cmd": "add", "deckFile": deckFile, "trnrunArgs": ["--help"]}).rejects(
      "Option not allowed in trnrunArgs: 'help'")
    check request(%*{"cmd": "add", "deckFile": deckFile, "trnrunArgs": ["--bogus:1"]}).rejects(
      "Unknown option in trnrunArgs: 'bogus'")

  test "cancel answers true once cancelled, then refuses":
    let simId = add(createDeck(dir, "wait-e.dck"))
    check request(%*{"cmd": "cancel", "simId": simId}) == %*{"ok": true}
    check simulation(simId)["trnrunStatus"].getStr() == "CANCELLED"
    check request(%*{"cmd": "cancel", "simId": simId}).rejects(
      "Cannot cancel simulation " & $simId & ": it is FINISHED")

  test "release refuses an unfinished simulation, then forgets a finished one":
    let simId = add(createDeck(dir, "wait-f.dck"))
    check request(%*{"cmd": "release", "simId": simId}).rejects(
      "Cannot release simulation " & $simId & ": it is RUNNING")
    discard request(%*{"cmd": "cancel", "simId": simId})
    check request(%*{"cmd": "release", "simId": simId}) == %*{"ok": true}
    check request(%*{"cmd": "get", "simId": simId}).rejects("Unknown simId: " & $simId)

  test "list returns the simulations in a state, oldest first":
    let
      running = add(createDeck(dir, "wait-g1.dck"))
      queued = [add(createDeck(dir, "wait-g2.dck")), add(createDeck(dir, "wait-g3.dck"))]
    proc simIds(state: string): seq[int] =
      ## The simIds `list` returns for `state`.
      let response = request(%*{"cmd": "list", "state": state})
      check response["ok"].getBool()
      result = @[]
      for simulation in response["simulations"]:
        result.add(simulation["simId"].getInt())
    check simIds("RUNNING") == @[running]
    check simIds("QUEUED") == @[queued[0], queued[1]]
    check running notin simIds("FINISHED")
    discard request(%*{"cmd": "cancel", "simId": running})
    check running in simIds("FINISHED")
    let listed = request(%*{"cmd": "list", "state": "RUNNING"})["simulations"][0]
    check listed == simulation(queued[0])
    check listed.hasKey("logs")

  test "list refuses a missing or unknown state":
    for node in [%*{"cmd": "list"}, %*{"cmd": "list", "state": "DONE"}]:
      check request(node).rejects("'state' must be QUEUED, RUNNING or FINISHED")

  test "unknown simIds are refused":
    for cmd in ["get", "cancel", "release"]:
      check request(%*{"cmd": cmd, "simId": 999}).rejects("Unknown simId: 999")

  test "a missing or non-integer simId is refused":
    check request(%*{"cmd": "get"}).rejects("'simId' must be an integer")
    check request(%*{"cmd": "get", "simId": "1"}).rejects("'simId' must be an integer")

  test "invalid commands are refused":
    check request(%*{"cmd": "launch"}).rejects("Unknown cmd: launch")
    check request(%*{"command": "ready"}).rejects("'cmd' must be a string")
    check request("[1,2]").rejects("Request must be a JSON object")

  test "malformed JSON is refused without raising":
    for line in ["", "{", "not json", """{"cmd":"ready"} trailing"""]:
      let response = request(line)
      check response["ok"].getBool() == false
      check response["error"].getStr().len > 0

removeDir(dir)
