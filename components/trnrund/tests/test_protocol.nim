import std/[json, os, sequtils, strutils, unittest]

import ../src/[protocol, scheduler]
import ./fake_trnrun


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc call(scheduler: Scheduler, request: JsonNode): JsonNode =
  ## Sends one request and parses its reply.
  parseJson(scheduler.handleRequest($request).reply)

proc logMessages(simulation: JsonNode): seq[string] =
  simulation["logs"].getElems().mapIt(it["message"].getStr())

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
        (line: """{"cmd":"changes","since":"1"}""", expected: ""),
        (line: """{"cmd":"changes","since":-1}""", expected: "since must not be negative: -1"),
        (line: """{"cmd":"remove","runId":"missing"}""", expected: "Unknown runId: missing"),
        (line: """{"cmd":"logs","runId":"a"}""", expected: "Unknown cmd: logs"),
        (line: """{"cmd":"collect","runId":"a"}""", expected: "Unknown cmd: collect"),
      ]
      # Replaced by `changes`, which covers all three.
      for cmd in ["states", "snapshot", "snapshots"]:
        checkpoint("removed cmd: " & cmd)
        check scheduler.call(%*{"cmd": cmd, "runId": "a"}) ==
          %*{"ok": false, "error": "Unknown cmd: " & cmd}
      for testCase in cases:
        checkpoint("request: " & testCase.line)
        let (reply, shutdown) = scheduler.handleRequest(testCase.line)
        let node = parseJson(reply)

        check not shutdown
        check node.len == 2
        check not node["ok"].getBool()
        check node["error"].getStr().len > 0
        check node["error"].getStr().contains(testCase.expected)

    test "adds a simulation and reports it, queued ones included, in submission order":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()

      check scheduler.call(%*{
        "cmd": "add", "runId": "b", "deckFile": doneDeck, "trnrunArgs": ["--pollMs:50"]
      }) == %*{"ok": true}
      discard scheduler.call(%*{"cmd": "add", "runId": "a", "deckFile": doneDeck})

      let simulations = scheduler.call(%*{"cmd": "changes"})["simulations"]
      check simulations.getElems().mapIt(it["runId"].getStr()) == @["b", "a"]
      check simulations.getElems().mapIt(it["state"].getStr()) == @["ACCEPTED", "QUEUED"]
      let simulation = simulations[0]
      check simulation["trnrunArgs"] == %*["--pollMs:50"]
      check "succeeded" in simulation
      check simulation["logStart"].getInt() == 0
      check simulation["logs"] == newJArray()

    test "changes return the simulations changed after since, with only newer logs":
      let scheduler = newScheduler(trnrun, 2)
      defer: scheduler.shutdown()
      check scheduler.call(%*{"cmd": "changes"}) ==
        %*{"ok": true, "revision": 0, "simulations": []}

      for runId in ["b", "a"]:
        discard scheduler.call(%*{"cmd": "add", "runId": runId, "deckFile": doneDeck})
      let submitted = scheduler.call(%*{"cmd": "changes"})
      let revision = submitted["revision"].getInt()
      check revision > 0
      check submitted["simulations"].getElems().mapIt(it["runId"].getStr()) == @["b", "a"]
      check scheduler.call(%*{"cmd": "changes", "since": revision}) ==
        %*{"ok": true, "revision": revision, "simulations": []}

      scheduler.shutdown() # Waits for both runs, three log entries each.
      let finished = scheduler.call(%*{"cmd": "changes", "since": revision})
      let latest = finished["revision"].getInt()
      check latest > revision
      check finished["simulations"].getElems().mapIt(it["runId"].getStr()) == @["b", "a"]
      for simulation in finished["simulations"]:
        checkpoint("runId: " & simulation["runId"].getStr())
        check simulation["state"].getStr() == "FINISHED"
        check simulation["revision"].getInt() > revision
        check simulation["logStart"].getInt() == 0
        check simulation.logMessages() == @["first", "second", "third"]

      # The latest change is the last run's exit, after all its log entries, so
      # a client up to date until then gets the outcome without repeated entries.
      let exit = scheduler.call(%*{"cmd": "changes", "since": latest - 1})["simulations"]
      check exit.len == 1
      check exit[0]["revision"].getInt() == latest
      check exit[0]["logStart"].getInt() == 3
      check exit[0]["logs"] == newJArray()
      # Counters always cover every entry, whatever logs leaves out.
      check exit[0]["notices"].getInt() + exit[0]["warnings"].getInt() == 3

    test "removes only finished simulations":
      let
        scheduler = newScheduler(trnrun, 2)
        gateDeck = createDeck(testDirectory, "gate-pending.dck")
      defer: scheduler.shutdown()
      discard scheduler.call(%*{"cmd": "add", "runId": "pending", "deckFile": gateDeck})
      discard scheduler.call(%*{"cmd": "add", "runId": "done", "deckFile": doneDeck})

      check scheduler.call(%*{"cmd": "remove", "runId": "pending"}) ==
        %*{"ok": false, "error": "Simulation has not finished: pending"}
      check scheduler.call(%*{"cmd": "changes"})["simulations"].len == 2

      writeFile(gateDeck.changeFileExt("release"), "")
      scheduler.shutdown()

      for runId in ["done", "pending"]:
        checkpoint("removed runId: " & runId)
        check scheduler.call(%*{"cmd": "remove", "runId": runId}) == %*{"ok": true}
        check scheduler.call(%*{"cmd": "remove", "runId": runId}) ==
          %*{"ok": false, "error": "Unknown runId: " & runId}
      check scheduler.call(%*{"cmd": "changes"})["simulations"] == newJArray()

    test "acknowledges shutdown and leaves it to the caller":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()

      let (reply, shutdown) = scheduler.handleRequest("""{"cmd":"shutdown"}""")
      check parseJson(reply) == %*{"ok": true}
      check shutdown
      check scheduler.call(%*{"cmd": "add", "runId": "a", "deckFile": doneDeck}) ==
        %*{"ok": true}

runTests()
