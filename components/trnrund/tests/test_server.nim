import std/[atomics, importutils, json, locks, monotimes, os, sequtils, strutils, tempfiles, times, unittest]
import db_connector/db_sqlite

import ../src/[job, messages, scheduler, server, workerpool]
import ./[fake_client, fake_deck, fake_trnrun]

privateAccess(Scheduler)

var
  outputLock: Lock
  written: seq[string] ## Every line written, guarded by `outputLock`.
  accepting: Atomic[bool] ## Whether writes succeed.

proc record(lines: seq[string]): bool {.nimcall, gcsafe, raises: [].} =
  ## Records the lines of one write; fails unless accepting.
  {.cast(gcsafe).}:
    withLock outputLock:
      written.add(lines)
  accepting.load()

proc writtenLines(): seq[string] =
  ## Every line written so far.
  withLock outputLock:
    result = written

proc post(scheduler: Scheduler, requests: varargs[JsonNode]) =
  ## Queues client requests for `serve`, as the stdin reader does.
  for request in requests:
    scheduler.requestInbox[].send(Message(kind: mkRequest, line: $request))

proc runTests() =
  ## Runs the server tests in a temporary directory.
  initLock(outputLock)
  initJobGuard()
  let testDirectory = createTempDir("trnrund-server-", "")
  defer: removeDir(testDirectory)
  let
    trnrun = getAppFilename()
    doneDeck = createDeck(testDirectory, "done.dck")

  suite "serving a client":
    setup:
      written = @[]
      accepting.store(true)

    test "replies in order, then notifies of later revisions, until shutdown completes":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "serve.sqlite3")
      scheduler.post(
        %*{"id": 1, "cmd": "ready"},
        %*{"id": 2, "cmd": "add", "deckFile": doneDeck},
        %*{"id": 3, "cmd": "shutdown"},
      )
      scheduler.serve(record)
      let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
      defer: reader.close()

      let lines = writtenLines()
      let replies = lines.filterIt("\"ok\"" in it).mapIt(parseJson(it))
      let events = lines.filterIt("\"event\"" in it).mapIt(parseJson(it))
      check replies.mapIt(it["id"].getInt()) == @[1, 2, 3]
      check lines[0..2].allIt("\"ok\"" in it) # The first batch's replies come first.
      check replies[0]["revision"].getInt() == 0
      check replies[1] == %*{"id": 2, "ok": true, "runId": 1}
      check events.len >= 2
      check events.allIt(it["event"].getStr() == "changed")
      let revisions = events.mapIt(it["revision"].getInt())
      check revisions[0] > 0 # Only revisions after the one the client started from.
      for index in 1..<revisions.len:
        check revisions[index] > revisions[index - 1]
      check $revisions[^1] == reader.getValue(sql"SELECT max(revision) FROM runs")
      check reader.getRow(sql"SELECT state, succeeded FROM runs") == @["FINISHED", "1"]
      check scheduler.isClosed

    test "a client that closes its input, or can no longer be written to, abandons the runs":
      for closedBy in ["input", "output"]:
        checkpoint(closedBy)
        written = @[]
        accepting.store(closedBy != "output")
        let
          deckFile = createDeck(testDirectory, "gate-" & closedBy & ".dck")
          scheduler = newScheduler(trnrun, 1, testDirectory / ("abandon-" & closedBy & ".sqlite3"))
        scheduler.post(%*{"cmd": "add", "deckFile": deckFile})
        if closedBy == "input":
          scheduler.requestInbox[].send(Message(kind: mkClosed))
        scheduler.serve(record)
        check scheduler.isClosed
        let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
        defer: reader.close()
        check reader.getRow(sql"SELECT state, error FROM runs") ==
          @["FINISHED", "Interrupted: the client disconnected"]
        scheduler.pool.shutdown()
        check not fileExists(deckFile.changeFileExt("released"))

    test "a client that does not read holds up the end of serving for the grace period only":
      openUnreadPipe()
      defer: closeUnreadPipe()
      for ending in ["input", "shutdown"]:
        checkpoint(ending)
        let scheduler = newScheduler(trnrun, 1, testDirectory / ("unread-" & ending & ".sqlite3"))
        for _ in 1..100: # Replies that fill the pipe.
          scheduler.post(%*{"cmd": "ready"})
        if ending == "input":
          scheduler.requestInbox[].send(Message(kind: mkClosed))
        else:
          scheduler.post(%*{"cmd": "shutdown"})
        let started = getMonoTime()
        scheduler.serve(writeUnread)
        check getMonoTime() - started < initDuration(seconds = 3)
        check scheduler.isClosed
        scheduler.pool.shutdown()

runTests()
