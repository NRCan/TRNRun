import std/[os, unittest]

include ../src/scheduler
import ./fake_trnrun


proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc release(deckFile: string) =
  ## Lets a `gate` run finish.
  writeFile(deckFile.changeFileExt("release"), "")

proc waitFor(scheduler: Scheduler, runId: string, state: SimulationState) =
  ## Applies worker messages until `runId` reaches at least `state`.
  while scheduler.registry[runId].state < state:
    scheduler.apply(scheduler.inbox.recv())

proc runIds(scheduler: Scheduler): seq[string] =
  result = @[]
  for simulation in scheduler:
    result.add(simulation.runId)

proc runTests() =
  let testDirectory = getTempDir() / "trnrund_scheduler_tests"
  if dirExists(testDirectory):
    removeDir(testDirectory)
  createDir(testDirectory)
  defer:
    if dirExists(testDirectory):
      removeDir(testDirectory)

  let
    trnrun = getAppFilename()
    doneDeck = createDeck(testDirectory, "done.dck")

  suite "scheduler":
    test "rejects an invalid worker count or TRNRun path":
      expect ValueError:
        discard newScheduler(trnrun, 0)
      expect ValueError:
        discard newScheduler(testDirectory / "missing-trnrun.exe", 1)

    test "rejects invalid submissions without registering them":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      scheduler.add("kept", doneDeck)

      let cases = [
        (runId: "", deckFile: doneDeck, trnrunArgs: newSeq[string]()),
        (runId: "kept", deckFile: doneDeck, trnrunArgs: newSeq[string]()),
        (runId: "missing", deckFile: testDirectory / "missing.dck", trnrunArgs: newSeq[string]()),
        (runId: "text", deckFile: createDeck(testDirectory, "deck.txt"), trnrunArgs: newSeq[string]()),
        (runId: "colon", deckFile: doneDeck, trnrunArgs: @["--deckFile:other.dck"]),
        (runId: "equals", deckFile: doneDeck, trnrunArgs: @["--deckFile=other.dck"]),
      ]
      for testCase in cases:
        checkpoint("runId: " & testCase.runId)
        expect ValueError:
          scheduler.add(testCase.runId, testCase.deckFile, testCase.trnrunArgs)

      check scheduler.runIds == @["kept"]

    test "runs a simulation through every state to a successful finish":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-lifecycle.dck")
      defer: scheduler.shutdown()

      scheduler.add("run", deckFile)
      check scheduler["run"].state == ssAccepted

      scheduler.waitFor("run", ssRunning)
      check scheduler["run"].state == ssRunning

      release(deckFile)
      scheduler.waitFor("run", ssFinished)
      let simulation = scheduler["run"]
      check simulation.status == some(StatusEvent(status: statusDone, message: ""))
      check simulation.exitCode == some(0)
      check simulation.logs.mapIt(it.message.get()) == @["first", "second", "third"]
      check simulation.notices == 2
      check simulation.warnings == 1
      check simulation.succeeded()

    test "finishes with an ERROR status when TRNRun fails or reports none":
      let scheduler = newScheduler(trnrun, 2)
      defer: scheduler.shutdown()
      scheduler.add("failed", createDeck(testDirectory, "failed.dck"))
      scheduler.add("silent", createDeck(testDirectory, "silent.dck"))
      scheduler.waitFor("failed", ssFinished)
      scheduler.waitFor("silent", ssFinished)

      check scheduler["failed"].status ==
        some(StatusEvent(status: statusError, message: "Fake failure"))
      check scheduler["failed"].exitCode == some(1)
      check scheduler["silent"].status == some(StatusEvent(
        status: statusError, message: "TRNRun exited without a terminal status"
      ))
      check scheduler["silent"].exitCode == some(0)
      check not scheduler["failed"].succeeded()
      check not scheduler["silent"].succeeded()

    test "queues runs beyond maxConcurrent and starts them as runs finish":
      let
        scheduler = newScheduler(trnrun, 1)
        firstDeck = createDeck(testDirectory, "gate-first.dck")
        secondDeck = createDeck(testDirectory, "gate-second.dck")
      defer: scheduler.shutdown()

      scheduler.add("first", firstDeck)
      scheduler.add("second", secondDeck)
      check scheduler["first"].state == ssAccepted
      check scheduler["second"].state == ssQueued

      release(firstDeck)
      scheduler.waitFor("first", ssFinished)
      check scheduler["second"].state in {ssAccepted, ssRunning}

      release(secondDeck)
      scheduler.waitFor("second", ssFinished)
      check scheduler["second"].succeeded()

    test "borrows simulations by runId and lists them in submission order":
      let scheduler = newScheduler(trnrun, 3)
      defer: scheduler.shutdown()

      expect KeyError:
        discard scheduler["unknown"]

      for runId in ["a", "b", "c"]:
        scheduler.add(runId, doneDeck)
      check scheduler.runIds == @["a", "b", "c"]

      scheduler.waitFor("b", ssFinished)
      scheduler.remove("b")
      scheduler.add("b", doneDeck)
      check scheduler.runIds == @["a", "c", "b"]

    test "removes only finished simulations, freeing their runId":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-remove.dck")
      defer: scheduler.shutdown()

      expect KeyError:
        scheduler.remove("unknown")

      scheduler.add("run", deckFile)
      expect ValueError:
        scheduler.remove("run")

      release(deckFile)
      scheduler.waitFor("run", ssFinished)
      scheduler.remove("run")
      expect KeyError:
        discard scheduler["run"]

      scheduler.add("run", deckFile)
      check scheduler["run"].state == ssAccepted

    test "shutdown cancels queued runs, waits for running ones, and is idempotent":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-shutdown.dck")

      scheduler.add("running", deckFile)
      scheduler.add("queued", doneDeck)
      release(deckFile)
      scheduler.shutdown()

      check scheduler["running"].state == ssFinished
      check scheduler["running"].succeeded()

      let queued = scheduler["queued"]
      check queued.state == ssFinished
      check queued.status ==
        some(StatusEvent(status: statusCancelled, message: "Not started"))
      check queued.exitCode.isNone
      check queued.error == "Not started: the daemon shut down"

      expect ValueError:
        scheduler.add("late", doneDeck)
      scheduler.shutdown()

runTests()
