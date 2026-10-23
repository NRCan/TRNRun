import std/[atomics, importutils, json, locks, monotimes, os, sequtils, strutils, tables, tempfiles, times, unittest]

import ../src/[job, messages, scheduler, server, workerpool]
import ./[fake_client, fake_deck, fake_trnrun]

privateAccess(Scheduler)

var
  outputLock: Lock
  written: seq[string] ## Every line written, guarded by `outputLock`.
  accepting: Atomic[bool] ## Whether writes succeed.
  closeAfter: string ## A line starting with this closes the client's input; guarded by `outputLock`.
  inbox: ptr Channel[Message] ## Where closing the client's input is posted.

proc record(lines: seq[string]): bool {.nimcall, gcsafe, raises: [].} =
  ## Records the lines of one write, closing the input after `closeAfter`; fails unless accepting.
  {.cast(gcsafe).}:
    withLock outputLock:
      written.add(lines)
      if closeAfter.len > 0 and lines.anyIt(it.startsWith(closeAfter)):
        inbox[].send(Message(kind: mkClosed))
  accepting.load()

proc writtenLines(): seq[string] =
  ## Every line written so far.
  withLock outputLock:
    result = written

proc post(scheduler: Scheduler, requests: varargs[JsonNode]) =
  ## Queues client requests for `serve`, as the stdin reader does.
  for request in requests:
    scheduler.requestInbox[].send(Message(kind: mkRequest, line: $request))

proc closeInput(scheduler: Scheduler) =
  ## Reports that the client closed its input, as the stdin reader does.
  scheduler.requestInbox[].send(Message(kind: mkClosed))

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
      closeAfter = ""
      accepting.store(true)

    test "replies once to each request, in order, and keeps answering after shutdown":
      let scheduler = newScheduler(trnrun, 1)
      scheduler.post(
        %*{"id": 1, "cmd": "ready"},
        %*{"id": 2, "cmd": "add", "deckFile": doneDeck},
        %*{"id": 3, "cmd": "shutdown"},
        %*{"id": 4, "cmd": "get", "runId": 1},
        %*{"id": 5, "cmd": "add", "deckFile": doneDeck},
      )
      scheduler.closeInput()
      scheduler.serve(record)

      let replies = writtenLines().mapIt(parseJson(it))
      check replies.mapIt(it["id"].getInt()) == @[1, 2, 3, 4, 5]
      check replies.allIt(it.hasKey("ok"))
      check replies[1]["runId"] == %1
      check replies[3]["run"]["runId"] == %1
      check replies[4]["error"] == %"The daemon is shutting down"
      check scheduler.isClosed

    test "a waiting add replies once its run finished, without holding up later replies":
      let scheduler = newScheduler(trnrun, 1)
      inbox = scheduler.requestInbox
      closeAfter = "{\"id\":\"w\""
      scheduler.post(
        %*{"id": "w", "cmd": "add", "deckFile": doneDeck, "waitFor": "FINISHED"},
        %*{"id": 2, "cmd": "get", "runId": 1},
      )
      scheduler.serve(record)

      let replies = writtenLines().mapIt(parseJson(it))
      check replies.mapIt(it["id"]) == @[%2, %"w"]
      check replies[0]["run"]["state"] == %"RUNNING"
      check replies[1]["runId"] == %1
      check replies[1]["run"]["succeeded"] == %true
      scheduler.pool.shutdown()

    test "a client that closes its input, or can no longer be written to, has TRNRun killed":
      for closedBy in ["input", "output"]:
        checkpoint(closedBy)
        written = @[]
        accepting.store(closedBy != "output")
        let
          deckFile = createDeck(testDirectory, "gate-" & closedBy & ".dck")
          scheduler = newScheduler(trnrun, 1)
        scheduler.post(%*{"cmd": "add", "deckFile": deckFile})
        if closedBy == "input":
          scheduler.closeInput()
        scheduler.serve(record)
        check scheduler.isClosed
        check scheduler.running.len == 0
        scheduler.pool.shutdown()
        check not fileExists(deckFile.changeFileExt("released"))

    test "closing the input drops waiting adds without replying":
      let
        deckFile = createDeck(testDirectory, "gate-dropped.dck")
        scheduler = newScheduler(trnrun, 1)
      scheduler.post(%*{"id": 1, "cmd": "add", "deckFile": deckFile, "waitFor": "FINISHED"})
      scheduler.closeInput()
      let started = getMonoTime()
      scheduler.serve(record)
      check getMonoTime() - started < initDuration(seconds = 3)
      check writtenLines().len == 0
      scheduler.pool.shutdown()

    test "a client that does not read holds up the end of serving for the grace period only":
      openUnreadPipe()
      defer: closeUnreadPipe()
      let scheduler = newScheduler(trnrun, 1)
      for _ in 1..100: # Replies that fill the pipe.
        scheduler.post(%*{"cmd": "ready"})
      scheduler.closeInput()
      let started = getMonoTime()
      scheduler.serve(writeUnread)
      check getMonoTime() - started < initDuration(seconds = 3)
      check scheduler.isClosed
      scheduler.pool.shutdown()

runTests()
