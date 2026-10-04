import std/[options, os, sequtils, unittest]

import ../src/[messages, workerpool]
import ./fake_trnrun


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc receiveUntilExited(inbox: var Channel[Message], runs: int): seq[Message] =
  ## Receives every message until `runs` simulations have exited.
  result = @[]
  var exited = 0
  while exited < runs:
    result.add(inbox.recv())
    if result[^1].kind == mkExited:
      inc exited

proc drain(inbox: var Channel[Message]): seq[Message] =
  ## Receives every message already posted.
  result = @[]
  while true:
    let (available, message) = inbox.tryRecv()
    if not available:
      return
    result.add(message)

proc runWork(runId, deckFile: string): Work =
  Work(kind: wkRun, runId: runId, deckFile: deckFile)

proc runTests() =
  let testDirectory = getTempDir() / "trnrund_workerpool_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  let
    trnrun = getAppFilename()
    doneDeck = createDeck(testDirectory, "done.dck")

  suite "worker pool":
    test "rejects invalid start arguments and a second start":
      var
        pool = default(WorkerPool)
        inbox = default(Channel[Message])
      inbox.open()

      expect ValueError:
        pool.start(trnrun, 0, addr inbox)
      expect ValueError:
        pool.start(trnrun, 1, nil)

      pool.start(trnrun, 1, addr inbox)
      expect ValueError:
        pool.start(trnrun, 1, addr inbox)
      pool.shutdown()
      expect ValueError:
        pool.start(trnrun, 1, addr inbox)

    test "accepts only run work, and only while running":
      var
        pool = default(WorkerPool)
        inbox = default(Channel[Message])
      inbox.open()

      expect ValueError:
        pool.submit(runWork("early", doneDeck))
      pool.start(trnrun, 1, addr inbox)
      expect ValueError:
        pool.submit(Work(kind: wkStop))
      pool.shutdown()
      expect ValueError:
        pool.submit(runWork("late", doneDeck))

    test "reports launch, every output line, then exit for each run":
      var
        pool = default(WorkerPool)
        inbox = default(Channel[Message])
      inbox.open()
      pool.start(trnrun, 2, addr inbox)
      defer: pool.shutdown()

      pool.submit(runWork("done", doneDeck))
      pool.submit(runWork("failed", createDeck(testDirectory, "failed.dck")))
      let messages = inbox.receiveUntilExited(2)

      let done = messages.filterIt(it.runId == "done")
      check done.mapIt(it.kind) ==
        @[mkLaunched] & repeat(mkOutput, DoneLines.len) & @[mkExited]
      check done.filterIt(it.kind == mkOutput).mapIt(it.line) == @DoneLines
      check done[^1].exitCode == some(0)
      check done[^1].error == ""

      let failed = messages.filterIt(it.runId == "failed")
      check failed[^1].kind == mkExited
      check failed[^1].exitCode == some(1)

    test "reports a launch failure as an exit without a code":
      var
        pool = default(WorkerPool)
        inbox = default(Channel[Message])
      inbox.open()
      pool.start(testDirectory / "missing-trnrun.exe", 1, addr inbox)
      defer: pool.shutdown()

      pool.submit(runWork("unlaunched", doneDeck))
      let messages = inbox.receiveUntilExited(1)

      check messages.len == 1
      check messages[0].exitCode.isNone
      check messages[0].error.len > 0

    test "shutdown finishes submitted work, then joins every worker":
      var
        pool = default(WorkerPool)
        inbox = default(Channel[Message])
      inbox.open()
      pool.shutdown() # Safe before start.

      pool.start(trnrun, 1, addr inbox)
      for index in 1 .. 3:
        pool.submit(runWork("run" & $index, doneDeck))
      pool.shutdown()
      pool.shutdown() # Safe when repeated.

      check inbox.drain().filterIt(it.kind == mkExited).mapIt(it.runId) ==
        @["run1", "run2", "run3"]

runTests()
