import std/[deques, importutils, json, os, sequtils, strutils, tables, tempfiles, unittest]
import db_connector/db_sqlite

import ../src/[database, messages, protocol, scheduler, workerpool]
import ./fake_trnrun

privateAccess(Scheduler)

proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc call(scheduler: Scheduler, client: var Client, request: JsonNode): JsonNode =
  parseJson(scheduler.handleRequest(client, $request))

proc call(scheduler: Scheduler, request: JsonNode): JsonNode =
  var client = Client()
  scheduler.call(client, request)

proc post(scheduler: Scheduler, requests: varargs[JsonNode]) =
  ## Queues client requests for `serve`, as the stdin reader does.
  for request in requests:
    scheduler.requestInbox[].send(Message(kind: mkRequest, line: $request))

proc runTests() =
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
      for _ in 0 ..< 2:
        check scheduler.call(%*{"cmd": "ready"}) == %*{
          "ok": true, "databasePath": path.absolutePath().normalizedPath(),
          "sessionId": 1, "revision": 0, "logId": 0,
        }

    test "repeats any request id first in its reply, also when rejected":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "ids.sqlite3")
      defer: scheduler.shutdown()
      for id in [%1, %"a-7", %*{"batch": [1, 2]}, newJNull()]:
        checkpoint($id)
        let reply = scheduler.handleRequest(
          (var client = Client(); client), $(%*{"id": id, "cmd": "pull"}))
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
        (line: """{"cmd":"add","deckFile":"x.dck","label":3}""", expected: "'label' must be a string"),
        (line: """{"cmd":"add","deckFile":"x.dck","trnrunArgs":"--clean"}""", expected: ""),
        (line: """{"cmd":"cancel"}""", expected: "Missing field: runId"),
        (line: """{"cmd":"cancel","runId":"1"}""", expected: "'runId' must be an integer"),
        (line: """{"cmd":"shutdown","cancelRunning":"yes"}""",
          expected: "'cancelRunning' must be true or false"),
      ]
      for testCase in cases:
        checkpoint("request: " & testCase.line)
        var client = Client()
        let node = parseJson(scheduler.handleRequest(client, testCase.line))
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
      check scheduler.call(%*{"cmd": "add", "deckFile": doneDeck, "trnrunArgs": ["--watchTMP:true"]}) ==
        %*{"ok": false, "error": "Unknown option in trnrunArgs: 'watchTMP'"}
      check 1 notin scheduler.database

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

    test "subscribe replies with the current revision and subscribes the client":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "subscribe.sqlite3")
      defer: scheduler.shutdown()
      var client = Client()
      discard scheduler.call(client, %*{"cmd": "add", "deckFile": doneDeck})
      check not client.subscribed
      check scheduler.call(client, %*{"cmd": "subscribe"}) ==
        %*{"ok": true, "revision": scheduler.database.savedRevision}
      check client.subscribed
      check client.notified == scheduler.database.savedRevision

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

  suite "serving a client":
    var written: seq[string] = @[]
    var accepting = true
    proc output(lines: seq[string]): bool =
      written.add(lines)
      accepting

    setup:
      written = @[]
      accepting = true

    test "replies in order, then notifies a subscriber once per batch, until shutdown completes":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "serve.sqlite3")
      scheduler.post(
        %*{"id": 1, "cmd": "ready"},
        %*{"id": 2, "cmd": "subscribe"},
        %*{"id": 3, "cmd": "add", "deckFile": doneDeck},
        %*{"id": 4, "cmd": "shutdown"},
      )
      scheduler.serve(output)
      let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
      defer: reader.close()

      let replies = written.filterIt("\"ok\"" in it).mapIt(parseJson(it))
      let events = written.filterIt("\"event\"" in it).mapIt(parseJson(it))
      check replies.mapIt(it["id"].getInt()) == @[1, 2, 3, 4]
      check written[0 .. 3].allIt("\"ok\"" in it) # The first batch's replies come first.
      check replies[1] == %*{"id": 2, "ok": true, "revision": 0}
      check replies[2] == %*{"id": 3, "ok": true, "runId": 1}
      check events.len >= 2
      check events.allIt(it["event"].getStr() == "changed")
      let revisions = events.mapIt(it["revision"].getInt())
      for index in 1 ..< revisions.len:
        check revisions[index] > revisions[index - 1]
      check $revisions[^1] == reader.getValue(sql"SELECT max(revision) FROM runs")
      check reader.getRow(sql"SELECT state, succeeded FROM runs") == @["FINISHED", "1"]
      check scheduler.isClosed

    test "does not notify a client that never subscribed":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "unsubscribed.sqlite3")
      scheduler.post(
        %*{"cmd": "add", "deckFile": doneDeck},
        %*{"cmd": "shutdown"},
      )
      scheduler.serve(output)
      check written == @["""{"ok":true,"runId":1}""", """{"ok":true}"""]

    test "a client that closes its input, or can no longer be written to, abandons the runs":
      for closedBy in ["input", "output"]:
        checkpoint(closedBy)
        written = @[]
        accepting = closedBy != "output"
        let
          deckFile = createDeck(testDirectory, "gate-" & closedBy & ".dck")
          scheduler = newScheduler(trnrun, 1, testDirectory / ("abandon-" & closedBy & ".sqlite3"))
        scheduler.post(%*{"cmd": "add", "deckFile": deckFile})
        if closedBy == "input":
          scheduler.requestInbox[].send(Message(kind: mkClosed))
        scheduler.serve(output)
        check scheduler.isClosed
        let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
        defer: reader.close()
        check reader.getRow(sql"SELECT state, error FROM runs") ==
          @["FINISHED", "Interrupted: the client disconnected"]
        scheduler.pool.shutdown()
        check not fileExists(deckFile.changeFileExt("released"))

runTests()
