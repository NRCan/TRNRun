import std/[options, os, osproc, sequtils, unittest]

import ../src/[messages, trnrun, workerpool]
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

proc readWork(runId: int, launched: Launched): Work =
  Work(kind: wkRead, runId: runId, output: launched.output, process: launched.waitHandle)

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
    test "reports every output line, then the exit, of each run":
      var
        pool = default(WorkerPool)
        inbox = default(Channel[Message])
      inbox.open()
      pool.start(2, addr inbox)
      defer: pool.shutdown()

      let
        done = launch(1, doneDeck, trnrun, [])
        failed = launch(2, createDeck(testDirectory, "failed.dck"), trnrun, [])
      defer:
        done.process.close()
        failed.process.close()
      pool.submit(readWork(1, done))
      pool.submit(readWork(2, failed))
      let messages = inbox.receiveUntilExited(2)

      let doneMessages = messages.filterIt(it.runId == 1)
      check doneMessages.mapIt(it.kind) == repeat(mkOutput, DoneLines.len) & @[mkExited]
      check doneMessages.filterIt(it.kind == mkOutput).mapIt(it.line) == @DoneLines
      check doneMessages[^1].exitCode == some(0)
      check doneMessages[^1].error == ""

      let failedMessages = messages.filterIt(it.runId == 2)
      check failedMessages[^1].kind == mkExited
      check failedMessages[^1].exitCode == some(1)

    test "reports the exit of a killed run once its output ends":
      var
        pool = default(WorkerPool)
        inbox = default(Channel[Message])
      inbox.open()
      pool.start(1, addr inbox)
      defer: pool.shutdown()

      let deckFile = createDeck(testDirectory, "gate-cancel.dck")
      let gate = launch(3, deckFile, trnrun, [])
      defer: gate.process.close()
      pool.submit(readWork(3, gate))
      gate.process.kill()
      let messages = inbox.receiveUntilExited(1)

      check messages.mapIt(it.kind) == @[mkExited]
      check messages[0].exitCode.isSome
      check not fileExists(deckFile.changeFileExt("released"))

    test "shutdown finishes submitted work, then joins every worker":
      var
        pool = default(WorkerPool)
        inbox = default(Channel[Message])
      inbox.open()
      pool.shutdown() # Safe before start.

      pool.start(1, addr inbox)
      var launched: seq[Launched] = @[]
      for runId in 1 .. 3:
        launched.add(launch(runId, doneDeck, trnrun, []))
        pool.submit(readWork(runId, launched[^1]))
      pool.shutdown()
      pool.shutdown() # Safe when repeated.
      for run in launched:
        run.process.close()

      check inbox.drain().filterIt(it.kind == mkExited).mapIt(it.runId) == @[1, 2, 3]

runTests()
