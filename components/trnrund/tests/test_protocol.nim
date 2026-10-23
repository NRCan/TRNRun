import std/[deques, importutils, json, monotimes, options, os, sequtils, strutils, tables, tempfiles, times, unittest]

import ../src/[events, job, protocol, scheduler]
import ./[fake_deck, fake_trnrun]

privateAccess(Scheduler)

proc call(scheduler: Scheduler, request: JsonNode): JsonNode =
  ## Runs one request and returns its parsed reply.
  parseJson(scheduler.handleRequest($request))

proc step(scheduler: Scheduler) =
  ## Applies the next batch of worker messages, as the daemon does.
  for message in scheduler.receive():
    scheduler.apply(message)

proc waitFinished(scheduler: Scheduler, runId: int) =
  ## Applies worker messages until `runId` finished.
  while scheduler.store[runId].state != ssFinished:
    scheduler.step()

proc shutdown(scheduler: Scheduler) =
  ## Shuts down without a client, applying worker messages until nothing runs, then closes.
  scheduler.requestShutdown()
  while not scheduler.isDone:
    scheduler.step()
  scheduler.close()

proc logEvent(message: string): SimulationEvent =
  ## A `Notice` log entry saying `message`.
  parseEventLine($(%*{"kind": "LOG", "severity": "Notice", "time": 0, "message": message})).get()

proc runTests() =
  ## Runs the protocol tests in a temporary directory.
  initJobGuard()
  let testDirectory = createTempDir("trnrund-protocol-", "")
  defer: removeDir(testDirectory)
  let
    trnrun = getAppFilename()
    doneDeck = createDeck(testDirectory, "done.dck")

  suite "client requests":
    test "ready reports the protocol and daemon versions and the concurrency limit":
      let scheduler = newScheduler(trnrun, 3)
      defer: scheduler.shutdown()
      for _ in 0..<2:
        check scheduler.call(%*{"cmd": "ready"}) == %*{
          "ok": true, "protocolVersion": 2, "version": NimblePkgVersion, "maxConcurrent": 3,
        }

    test "repeats any request id first in its reply, also when rejected":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      for id in [%1, %"a-7", %*{"batch": [1, 2]}, newJNull()]:
        checkpoint($id)
        let reply = scheduler.handleRequest($(%*{"id": id, "cmd": "pull"}))
        check reply.startsWith("{\"id\":" & $id & ",")
        check parseJson(reply) == %*{"id": id, "ok": false, "error": "Unknown cmd: pull"}
      check scheduler.call(%*{"cmd": "cancel", "runId": 9}) ==
        %*{"ok": false, "error": "Unknown runId: 9"}

    test "rejects malformed and unknown requests":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      let cases = [
        (line: "garbage", expected: ""),
        (line: "[1]", expected: "Request must be a JSON object"),
        (line: "{}", expected: "Missing field: cmd"),
        (line: """{"cmd":5}""", expected: "'cmd' must be a string"),
        (line: """{"cmd":"pull"}""", expected: "Unknown cmd: pull"),
        (line: """{"cmd":"add"}""", expected: "Missing field: deckFile"),
        (line: """{"cmd":"add","deckFile":3}""", expected: "'deckFile' must be a string"),
        (line: """{"cmd":"add","deckFile":"x.dck","label":3}""",
          expected: "'label' must be a string"),
        (line: """{"cmd":"add","deckFile":"x.dck","trnrunArgs":"--clean"}""",
          expected: "'trnrunArgs' must be an array of strings"),
        (line: """{"cmd":"add","deckFile":"x.dck","trnrunArgs":["--clean",1]}""",
          expected: "'trnrunArgs' must be an array of strings"),
        (line: """{"cmd":"add","deckFile":"x.dck","waitFor":"STARTED"}""",
          expected: "'waitFor' must be QUEUED, RUNNING or FINISHED"),
        (line: """{"cmd":"add","deckFile":"x.dck","waitFor":"RUNNING"}""",
          expected: "'waitFor' needs an 'id' to match its reply"),
        (line: """{"cmd":"cancel"}""", expected: "Missing field: runId"),
        (line: """{"cmd":"cancel","runId":"1"}""", expected: "'runId' must be an integer"),
        (line: """{"cmd":"get"}""", expected: "Missing field: runId"),
        (line: """{"cmd":"get","runId":1}""", expected: "Unknown runId: 1"),
        (line: """{"cmd":"list"}""", expected: "Unknown cmd: list"),
        (line: """{"cmd":"release"}""", expected: "Missing field: runId"),
        (line: """{"cmd":"release","runId":[1]}""", expected: "'runId' must be an integer"),
        (line: """{"cmd":"shutdown","cancelRunning":"yes"}""",
          expected: "'cancelRunning' must be true or false"),
      ]
      for testCase in cases:
        checkpoint("request: " & testCase.line)
        let node = parseJson(scheduler.handleRequest(testCase.line))
        check node.len == 2
        check not node["ok"].getBool()
        check node["error"].getStr().contains(testCase.expected)
      check not scheduler.isShuttingDown
      check 1 notin scheduler.store

    test "add replies with the new runId and run, keeping its arguments and label":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      let first = scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})
      check first["runId"] == %1
      check first["run"]["runId"] == %1
      check first["run"]["state"] == %"RUNNING" # Launched before the reply.
      let second = scheduler.call(%*{
        "cmd": "add", "deckFile": doneDeck, "trnrunArgs": ["--pollMs:50"], "label": "second",
        "runId": "ignored",
      })
      check (second["runId"], second["run"]["state"]) == (%2, %"QUEUED")
      check (second["run"]["label"], second["run"]["trnrunArgs"]) == (%"second", %["--pollMs:50"])
      let third = scheduler.call(%*{
        "cmd": "add", "deckFile": doneDeck, "trnrunArgs": nil, "label": nil, "waitFor": "QUEUED"
      })
      check (third["runId"], third["run"]["label"], third["run"]["trnrunArgs"]) ==
        (%3, newJNull(), %[])
      check scheduler.running.len == 1
      check scheduler.queue.len == 2

    test "add with waitFor replies later, through takeReplies":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      check scheduler.handleRequest($(%*{
        "id": "w", "cmd": "add", "deckFile": doneDeck, "waitFor": "FINISHED"
      })) == ""
      check scheduler.takeReplies().len == 0
      check scheduler.call(%*{"cmd": "get", "runId": 1})["ok"] == %true # Answered meanwhile.
      scheduler.waitFinished(1)
      let replies = scheduler.takeReplies().mapIt(parseJson(it))
      check replies.len == 1
      check (replies[0]["id"], replies[0]["ok"], replies[0]["runId"]) == (%"w", %true, %1)
      check replies[0]["run"] == scheduler.call(%*{"cmd": "get", "runId": 1})["run"]
      check replies[0]["run"]["succeeded"] == %true

    test "invalid submissions remain ordinary error replies":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      check not scheduler.call(%*{"cmd": "add", "deckFile": "missing.dck"})["ok"].getBool()
      let request = %*{"cmd": "add", "deckFile": doneDeck, "trnrunArgs": ["--watchTMP:true"]}
      check scheduler.call(request) ==
        %*{"ok": false, "error": "Unknown option in trnrunArgs: 'watchTMP'"}
      check 1 notin scheduler.store

    test "get replies with one run and all its logs":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      let runId = scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})["runId"].getInt()
      scheduler.waitFinished(runId)
      let reply = scheduler.call(%*{"cmd": "get", "runId": runId})
      check reply.len == 2
      check reply["run"]["notices"] == %2
      let logs = reply["run"]["logs"]
      check logs.elems.mapIt(it["message"].getStr()) == @["first", "second", "third"]
      check logs[1] == %*{
        "severity": "Warning", "simTime": 5.0, "unitId": nil,
        "typeId": nil, "messageCode": nil, "message": "second", "information": nil,
      }

    test "release deletes a finished run only, skipping an unknown one":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      discard scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})
      check scheduler.call(%*{"cmd": "release", "runId": 1}) ==
        %*{"ok": false, "error": "Run 1 is not FINISHED"}
      scheduler.waitFinished(1)
      check scheduler.call(%*{"cmd": "release", "runId": 1}) == %*{"ok": true}
      check scheduler.call(%*{"cmd": "release", "runId": 1}) == %*{"ok": true}
      check scheduler.call(%*{"cmd": "get", "runId": 1}) ==
        %*{"ok": false, "error": "Unknown runId: 1"}
      check scheduler.call(%*{"cmd": "cancel", "runId": 1}) ==
        %*{"ok": false, "error": "Unknown runId: 1"}

    test "cancel acknowledges only, after a queued run is stored as cancelled":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      discard scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})
      let queued = scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})["runId"]
      check scheduler.call(%*{"cmd": "cancel", "runId": queued}) == %*{"ok": true}
      let run = scheduler.call(%*{"cmd": "get", "runId": queued})["run"]
      check (run["state"], run["trnrunStatus"]) == (%"FINISHED", %"CANCELLED")
      check scheduler.queue.len == 0

    test "shutdown stops new runs, and later requests are still answered":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      discard scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})
      check scheduler.call(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check scheduler.isShuttingDown
      check scheduler.call(%*{"cmd": "add", "deckFile": doneDeck}) ==
        %*{"ok": false, "error": "The daemon is shutting down"}
      check scheduler.call(%*{"cmd": "get", "runId": 1})["ok"] == %true
      check scheduler.call(%*{"cmd": "shutdown", "cancelRunning": true}) == %*{"ok": true}

    test "a run with 10,000 log entries replies well under a second":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      let runId = scheduler.store.submit(doneDeck) # Stored, not queued, so it never launches.
      for index in 1..10_000:
        scheduler.store.record(runId, logEvent("entry " & $index))

      let started = getMonoTime()
      let reply = scheduler.handleRequest($(%*{"cmd": "get", "runId": runId}))
      let elapsed = getMonoTime() - started
      checkpoint("replied in " & $elapsed)
      check elapsed < initDuration(milliseconds = 500)
      check parseJson(reply)["run"]["logs"].len == 10_000

runTests()
