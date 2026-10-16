import std/[deques, importutils, json, os, strutils, tables, tempfiles, unittest]
import db_connector/db_sqlite

import ../src/[job, protocol, scheduler]
import ./[fake_deck, fake_trnrun]

privateAccess(Scheduler)

proc call(scheduler: Scheduler, request: JsonNode): JsonNode =
  ## Runs one request and returns its parsed reply.
  parseJson(scheduler.handleRequest($request))

proc shutdown(scheduler: Scheduler) =
  ## Shuts down without a client, applying worker messages until nothing runs, then closes.
  scheduler.requestShutdown()
  while not scheduler.isDone:
    let messages = scheduler.receive()
    scheduler.atomically:
      for message in messages:
        scheduler.apply(message)
  scheduler.close()

proc runTests() =
  ## Runs the protocol tests in a temporary directory.
  initJobGuard()
  let testDirectory = createTempDir("trnrund-protocol-", "")
  defer: removeDir(testDirectory)
  let
    trnrun = getAppFilename()
    doneDeck = createDeck(testDirectory, "done.dck")

  suite "client requests":
    test "ready reports the database, session, and read positions, repeatably":
      let path = testDirectory / "nested" / ".." / "ready.sqlite3"
      let scheduler = newScheduler(trnrun, 1, path)
      defer: scheduler.shutdown()
      for _ in 0..<2:
        check scheduler.call(%*{"cmd": "ready"}) == %*{
          "ok": true, "databasePath": path.absolutePath().normalizedPath(),
          "sessionId": 1, "revision": 0, "logId": 0,
        }

    test "repeats any request id first in its reply, also when rejected":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "ids.sqlite3")
      defer: scheduler.shutdown()
      for id in [%1, %"a-7", %*{"batch": [1, 2]}, newJNull()]:
        checkpoint($id)
        let reply = scheduler.handleRequest($(%*{"id": id, "cmd": "pull"}))
        check reply.startsWith("{\"id\":" & $id & ",")
        check parseJson(reply) == %*{"id": id, "ok": false, "error": "Unknown cmd: pull"}
      check scheduler.call(%*{"cmd": "cancel", "runId": 9}) ==
        %*{"ok": false, "error": "Unknown runId: 9"}

    test "rejects malformed and unknown requests":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "malformed.sqlite3")
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
        (line: """{"cmd":"cancel"}""", expected: "Missing field: runId"),
        (line: """{"cmd":"cancel","runId":"1"}""", expected: "'runId' must be an integer"),
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

    test "add replies with the new runId and saves its arguments and label":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "order.sqlite3")
      defer: scheduler.shutdown()
      check scheduler.call(%*{"cmd": "add", "deckFile": doneDeck}) == %*{"ok": true, "runId": 1}
      check scheduler.call(%*{
        "cmd": "add", "deckFile": doneDeck, "trnrunArgs": ["--pollMs:50"], "label": "second",
        "runId": "ignored",
      }) == %*{"ok": true, "runId": 2}
      check scheduler.call(%*{
        "cmd": "add", "deckFile": doneDeck, "trnrunArgs": nil, "label": nil
      }) == %*{"ok": true, "runId": 3}
      let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
      defer: reader.close()
      reader.exec(sql"PRAGMA query_only = ON")
      check reader.getAllRows(sql"SELECT run_id, label, trnrun_args FROM runs ORDER BY run_id") ==
        @[@["1", "", "[]"], @["2", "second", """["--pollMs:50"]"""], @["3", "", "[]"]]
      check scheduler.running.len == 1
      check scheduler.queue.len == 2

    test "invalid submissions remain ordinary error replies":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "invalid.sqlite3")
      defer: scheduler.shutdown()
      check not scheduler.call(%*{"cmd": "add", "deckFile": "missing.dck"})["ok"].getBool()
      let request = %*{"cmd": "add", "deckFile": doneDeck, "trnrunArgs": ["--watchTMP:true"]}
      check scheduler.call(request) ==
        %*{"ok": false, "error": "Unknown option in trnrunArgs: 'watchTMP'"}
      check 1 notin scheduler

    test "cancel acknowledges only, after a queued run is saved as cancelled":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "cancel.sqlite3")
      defer: scheduler.shutdown()
      discard scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})
      let queued = scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})["runId"]
      check scheduler.call(%*{"cmd": "cancel", "runId": queued}) == %*{"ok": true}
      let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
      defer: reader.close()
      reader.exec(sql"PRAGMA query_only = ON")
      check reader.getRow(sql"SELECT state, trnrun_status FROM runs WHERE run_id = 2") ==
        @["FINISHED", "CANCELLED"]
      check scheduler.queue.len == 0

    test "shutdown starts shutting down, and later adds are rejected":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "shutdown.sqlite3")
      defer: scheduler.shutdown()
      check scheduler.call(%*{"cmd": "shutdown"}) == %*{"ok": true}
      check scheduler.isShuttingDown
      check scheduler.call(%*{"cmd": "add", "deckFile": doneDeck}) ==
        %*{"ok": false, "error": "The daemon is shutting down"}
      check scheduler.call(%*{"cmd": "shutdown", "cancelRunning": true}) == %*{"ok": true}

    test "database failures escape instead of becoming error replies":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "failure.sqlite3")
      defer: scheduler.shutdown()
      let connection = db_sqlite.open(scheduler.databasePath, "", "", "")
      defer: connection.close()
      connection.exec(sql"""CREATE TRIGGER fail_submission BEFORE INSERT ON runs
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
      expect DbError:
        discard scheduler.call(%*{"cmd": "add", "deckFile": doneDeck})
      check connection.getValue(sql"SELECT count(*) FROM runs") == "0"
      check scheduler.running.len == 0
      check scheduler.queue.len == 0
      connection.exec(sql"DROP TRIGGER fail_submission")

runTests()
