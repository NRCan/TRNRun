import std/[json, os, sequtils, strutils, unittest]

import ../src/[protocol, scheduler]
import ./fake_trnrun


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc call(scheduler: Scheduler, request: JsonNode): JsonNode =
  ## Sends one request and parses its reply.
  parseJson(scheduler.handleRequest($request).reply)

proc logMessages(reply: JsonNode): seq[string] =
  reply["logs"].getElems().mapIt(it["message"].getStr())

proc runTests() =
  let testDirectory = getTempDir() / "trnrund_protocol_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  let
    trnrun = getAppFilename()
    doneDeck = createDeck(testDirectory, "done.dck")

  suite "client protocol":
    test "replies ok:false with the cause to malformed requests":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()

      let cases = [
        (line: "garbage", expected: ""),
        (line: "[1]", expected: "Request must be a JSON object"),
        (line: "{}", expected: "Missing field: cmd"),
        (line: """{"cmd":"launch"}""", expected: "Unknown cmd: launch"),
        (line: """{"cmd":"add"}""", expected: "Missing field: runId"),
        (line: """{"cmd":"add","runId":"a"}""", expected: "Missing field: deckFile"),
        (line: """{"cmd":"snapshot","runId":7}""", expected: ""),
        (line: """{"cmd":"logs","runId":"missing"}""", expected: "Unknown runId: missing"),
      ]
      for testCase in cases:
        checkpoint("request: " & testCase.line)
        let (reply, shutdown) = scheduler.handleRequest(testCase.line)
        let node = parseJson(reply)

        check not shutdown
        check node.len == 2
        check not node["ok"].getBool()
        check node["error"].getStr().len > 0
        check node["error"].getStr().contains(testCase.expected)

    test "adds a simulation and snapshots it without logs":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()

      check scheduler.call(%*{
        "cmd": "add", "runId": "a", "deckFile": doneDeck, "trnrunArgs": ["--pollMs:50"]
      }) == %*{"ok": true}

      let reply = scheduler.call(%*{"cmd": "snapshot", "runId": "a"})
      check reply["ok"].getBool()
      let simulation = reply["simulation"]
      check simulation["runId"].getStr() == "a"
      check simulation["trnrunArgs"] == %*["--pollMs:50"]
      check simulation["state"].getStr() == "ACCEPTED"
      check "succeeded" in simulation
      check "logs" notin simulation

    test "snapshots every simulation in submission order, or the listed ones":
      let scheduler = newScheduler(trnrun, 2)
      defer: scheduler.shutdown()
      for runId in ["b", "a"]:
        discard scheduler.call(%*{"cmd": "add", "runId": runId, "deckFile": doneDeck})

      let all = scheduler.call(%*{"cmd": "snapshots"})
      check all["simulations"].getElems().mapIt(it["runId"].getStr()) == @["b", "a"]

      let listed = scheduler.call(%*{"cmd": "snapshots", "runIds": ["a"]})
      check listed["simulations"].getElems().mapIt(it["runId"].getStr()) == @["a"]

      let unknown = scheduler.call(%*{"cmd": "snapshots", "runIds": ["a", "missing"]})
      check unknown == %*{"ok": false, "error": "Unknown runId: missing"}

    test "slices logs like Python":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      discard scheduler.call(%*{"cmd": "add", "runId": "run", "deckFile": doneDeck})
      scheduler.shutdown() # Waits for the run, whose logs stay readable.

      let cases = [
        (bounds: %*{}, expected: @["first", "second", "third"]),
        (bounds: %*{"start": 1}, expected: @["second", "third"]),
        (bounds: %*{"stop": -1}, expected: @["first", "second"]),
        (bounds: %*{"start": -1}, expected: @["third"]),
        (bounds: %*{"start": -10, "stop": 10}, expected: @["first", "second", "third"]),
        (bounds: %*{"start": 5}, expected: newSeq[string]()),
        (bounds: %*{"start": 2, "stop": 1}, expected: newSeq[string]()),
      ]
      for testCase in cases:
        checkpoint("bounds: " & $testCase.bounds)
        let request = %*{"cmd": "logs", "runId": "run"}
        for key, value in testCase.bounds:
          request[key] = value
        check scheduler.call(request).logMessages() == testCase.expected

    test "removes and collects only finished simulations":
      let
        scheduler = newScheduler(trnrun, 2)
        gateDeck = createDeck(testDirectory, "gate-pending.dck")
      defer: scheduler.shutdown()
      discard scheduler.call(%*{"cmd": "add", "runId": "pending", "deckFile": gateDeck})
      discard scheduler.call(%*{"cmd": "add", "runId": "done", "deckFile": doneDeck})

      for cmd in ["remove", "collect"]:
        checkpoint("cmd: " & cmd)
        check scheduler.call(%*{"cmd": cmd, "runId": "pending"}) ==
          %*{"ok": false, "error": "Simulation has not finished: pending"}
      check scheduler.call(%*{"cmd": "snapshot", "runId": "pending"})["ok"].getBool()

      writeFile(gateDeck.changeFileExt("release"), "")
      scheduler.shutdown()

      let collected = scheduler.call(%*{"cmd": "collect", "runId": "done"})
      check collected["simulation"]["state"].getStr() == "FINISHED"
      check collected["simulation"]["succeeded"].getBool()
      check "logs" notin collected["simulation"]
      check collected.logMessages() == @["first", "second", "third"]

      check scheduler.call(%*{"cmd": "remove", "runId": "pending"}) == %*{"ok": true}
      for runId in ["done", "pending"]:
        checkpoint("forgotten runId: " & runId)
        check scheduler.call(%*{"cmd": "snapshot", "runId": runId}) ==
          %*{"ok": false, "error": "Unknown runId: " & runId}

    test "acknowledges shutdown and leaves it to the caller":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()

      let (reply, shutdown) = scheduler.handleRequest("""{"cmd":"shutdown"}""")
      check parseJson(reply) == %*{"ok": true}
      check shutdown
      check scheduler.call(%*{"cmd": "add", "runId": "a", "deckFile": doneDeck}) ==
        %*{"ok": true}

runTests()
