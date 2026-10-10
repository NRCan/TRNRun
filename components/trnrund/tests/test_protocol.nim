import std/[deques, importutils, json, os, strutils, tables, tempfiles, unittest]
import db_connector/db_sqlite

import ../src/[database, messages, protocol, scheduler]
import ./fake_trnrun

privateAccess(Scheduler) # TRNRun arguments are only in memory: they are not saved.

proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc call(scheduler: Scheduler, request: JsonNode): JsonNode =
  parseJson(scheduler.handleRequest($request).reply)

proc runTests() =
  let testDirectory = createTempDir("trnrund-protocol-", "")
  defer: removeDir(testDirectory)
  let
    trnrun = getAppFilename()
    doneDeck = createDeck(testDirectory, "done.dck")

  suite "client protocol":
    test "ready reports the normalized database path, repeatably":
      let path = testDirectory / "nested" / ".." / "ready.sqlite3"
      let scheduler = newScheduler(trnrun, 1, path)
      defer: scheduler.shutdown()
      for _ in 0 ..< 2:
        let (reply, shutdown) = scheduler.handleRequest("""{"cmd":"ready"}""")
        check parseJson(reply) ==
          %*{"ok": true, "databasePath": path.absolutePath().normalizedPath()}
        check not shutdown

    test "rejects malformed and unknown requests without requesting shutdown":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "malformed.sqlite3")
      defer: scheduler.shutdown()
      let cases = [
        (line: "garbage", expected: ""),
        (line: "[1]", expected: "Request must be a JSON object"),
        (line: "{}", expected: "Missing field: cmd"),
        (line: """{"cmd":"pull"}""", expected: "Unknown cmd: pull"),
        (line: """{"cmd":"add"}""", expected: "Missing field: runId"),
        (line: """{"cmd":"add","runId":"a"}""", expected: "Missing field: deckFile"),
      ]
      for testCase in cases:
        checkpoint("request: " & testCase.line)
        let (reply, shutdown) = scheduler.handleRequest(testCase.line)
        let node = parseJson(reply)
        check not shutdown
        check node.len == 2
        check not node["ok"].getBool()
        check node["error"].getStr().contains(testCase.expected)

    test "add acknowledges only and preserves submission order and arguments":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "order.sqlite3")
      defer: scheduler.shutdown()
      check scheduler.call(%*{
        "cmd": "add", "runId": "b", "deckFile": doneDeck, "trnrunArgs": ["--pollMs:50"]
      }) == %*{"ok": true, "state": "ACCEPTED"}
      check scheduler.call(%*{"cmd": "add", "runId": "a", "deckFile": doneDeck}) ==
        %*{"ok": true, "state": "QUEUED"}
      check scheduler.running["b"].state == ssAccepted
      check scheduler.running["b"].trnrunArgs == @["--pollMs:50"]
      check "a" notin scheduler.running
      check scheduler.queue.len == 1

    test "invalid submissions remain ordinary error replies":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "invalid.sqlite3")
      defer: scheduler.shutdown()
      check not scheduler.call(%*{
        "cmd": "add", "runId": "", "deckFile": doneDeck
      })["ok"].getBool()
      check not scheduler.call(%*{
        "cmd": "add", "runId": "a", "deckFile": "missing.dck"
      })["ok"].getBool()
      check "a" notin scheduler.database
      discard scheduler.call(%*{"cmd": "add", "runId": "a", "deckFile": doneDeck})
      check not scheduler.call(%*{
        "cmd": "add", "runId": "a", "deckFile": doneDeck
      })["ok"].getBool()
      check not scheduler.call(%*{
        "cmd": "add", "runId": "b", "deckFile": doneDeck, "until": "DONE"
      })["ok"].getBool()
      check "b" notin scheduler.database

    test "add waits for until, deferring the requests that arrive meanwhile":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "until.sqlite3")
        gate = createDeck(testDirectory, "gate-until.dck")
        ready = $(%*{"cmd": "ready"})
      defer: scheduler.shutdown()
      scheduler.requestInbox[].send(Message(kind: mkRequest, line: ready))
      check scheduler.call(%*{
        "cmd": "add", "runId": "done", "deckFile": doneDeck, "until": "FINISHED"
      }) == %*{"ok": true, "state": "FINISHED"}
      check scheduler.nextRequest().line == ready

      check scheduler.call(%*{"cmd": "add", "runId": "gate", "deckFile": gate}) ==
        %*{"ok": true, "state": "ACCEPTED"}
      writeFile(gate.changeFileExt("release"), "")
      check scheduler.call(%*{ # Queued behind the gate until it exits.
        "cmd": "add", "runId": "next", "deckFile": doneDeck, "until": "ACCEPTED"
      }) == %*{"ok": true, "state": "ACCEPTED"}
      check "gate" notin scheduler.running

    test "a client leaving ends the wait and drops its deferred requests":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "leave.sqlite3")
        gate = createDeck(testDirectory, "gate-leave.dck")
      defer: scheduler.shutdown()
      scheduler.requestInbox[].send(Message(kind: mkRequest, line: $(%*{"cmd": "ready"})))
      scheduler.requestInbox[].send(Message(kind: mkClosed))
      let reply = scheduler.call(%*{
        "cmd": "add", "runId": "run", "deckFile": gate, "until": "FINISHED"
      })
      check reply["state"].getStr() in ["ACCEPTED", "RUNNING"]
      check scheduler.nextRequest().kind == mkClosed
      writeFile(gate.changeFileExt("release"), "") # Lets shutdown join the worker.

    test "database failures escape instead of becoming error replies":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "failure.sqlite3")
      defer: scheduler.shutdown()
      let connection = db_sqlite.open(scheduler.databasePath, "", "", "")
      defer: connection.close()
      connection.exec(sql"""CREATE TRIGGER fail_submission BEFORE INSERT ON runs
        BEGIN SELECT RAISE(ABORT, 'injected failure'); END""")
      expect DatabaseError:
        discard scheduler.call(%*{"cmd": "add", "runId": "run", "deckFile": doneDeck})
      connection.exec(sql"DROP TRIGGER fail_submission")

    test "acknowledges shutdown and leaves it to the caller":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "shutdown.sqlite3")
      defer: scheduler.shutdown()
      let (reply, shutdown) = scheduler.handleRequest("""{"cmd":"shutdown"}""")
      check parseJson(reply) == %*{"ok": true}
      check shutdown
      check scheduler.call(%*{"cmd": "add", "runId": "a", "deckFile": doneDeck}) ==
        %*{"ok": true, "state": "ACCEPTED"}

runTests()
