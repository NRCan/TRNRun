import std/[json, os, sequtils, unittest]

include ../src/scheduler
import ../src/job
import ./[fake_deck, fake_trnrun]

proc release(deckFile: string) =
  ## Lets a `gate` run finish.
  writeFile(deckFile.changeFileExt("release"), "")

proc stateOf(scheduler: Scheduler, runId: int): SimulationState =
  ## Stored state of `runId`.
  scheduler.store[runId].state

proc step(scheduler: Scheduler) =
  ## Applies the next batch of worker messages, as the daemon does.
  for message in scheduler.receive():
    scheduler.apply(message)

proc waitFor(scheduler: Scheduler, runId: int, state: SimulationState) =
  ## Applies worker messages until `runId` reaches at least `state`.
  while scheduler.stateOf(runId) < state:
    scheduler.step()

proc shutdown(scheduler: Scheduler, cancelRunning = false) =
  ## Shuts down as a client would, applying worker messages until nothing
  ## runs, then closes. Idempotent, and a no-op after `abandon`.
  scheduler.requestShutdown(cancelRunning)
  while not scheduler.isDone:
    scheduler.step()
  scheduler.close()

proc parsedReplies(scheduler: Scheduler): seq[JsonNode] =
  ## The replies to waiting adds so far, parsed.
  scheduler.takeReplies().mapIt(parseJson(it))

proc runTests() =
  ## Runs the scheduler tests in a temporary directory.
  initJobGuard()
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
      expect InputError:
        discard newScheduler(trnrun, 0)
      expect InputError:
        discard newScheduler(testDirectory / "missing-trnrun.exe", 1)

    test "numbers runs and rejects invalid submissions without storing them":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      check scheduler.add(doneDeck) == 1
      check scheduler.add(doneDeck, label = some("second")) == 2

      let cases = [
        (deckFile: testDirectory / "missing.dck", trnrunArgs: newSeq[string]()),
        (deckFile: createDeck(testDirectory, "deck.txt"), trnrunArgs: newSeq[string]()),
        (deckFile: doneDeck, trnrunArgs: @["--deckFile:other.dck"]),
        (deckFile: doneDeck, trnrunArgs: @["--runId:7"]),
        (deckFile: doneDeck, trnrunArgs: @["--pollMs:50", "--watchTMP:true"]),
      ]
      for testCase in cases:
        checkpoint("case: " & $testCase)
        expect InputError:
          discard scheduler.add(testCase.deckFile, testCase.trnrunArgs)
      check 3 notin scheduler.store
      check scheduler.store[2].label == some("second")

    test "launches a run at once and finishes it successfully, with its logs":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-lifecycle.dck")
      defer: scheduler.shutdown()

      let runId = scheduler.add(deckFile)
      check scheduler.stateOf(runId) == ssRunning
      check scheduler.store[runId].startedAt.isSome

      release(deckFile)
      scheduler.waitFor(runId, ssFinished)
      let run = scheduler.store[runId]
      check (run.trnrunStatus, run.trnrunMessage, run.exitCode, run.notices, run.warnings,
        run.succeeded) == (some(stDone), some(""), some(0), 2, 1, some(true))
      check run.submittedAt <= run.startedAt.get() and run.startedAt.get() <= run.finishedAt.get()
      check run.logs.mapIt(it.message.get()) == @["first", "second", "third"]

    test "finishes with an ERROR status when TRNRun fails or reports none":
      let scheduler = newScheduler(trnrun, 2)
      defer: scheduler.shutdown()
      let
        failed = scheduler.add(createDeck(testDirectory, "failed.dck"))
        silent = scheduler.add(createDeck(testDirectory, "silent.dck"))
      scheduler.waitFor(failed, ssFinished)
      scheduler.waitFor(silent, ssFinished)

      proc outcome(run: Run): auto =
        ## The fields that tell a failure.
        (run.trnrunStatus, run.trnrunMessage, run.exitCode, run.succeeded)
      check scheduler.store[failed].outcome ==
        (some(stError), some("Fake failure"), some(1), some(false))
      check scheduler.store[silent].outcome ==
        (some(stError), some("TRNRun exited without a terminal status"), some(0), some(false))

    test "a run whose TRNRun cannot start finishes from QUEUED and frees its slot":
      let
        notAnExe = createDeck(testDirectory, "not-an-exe.exe")
        scheduler = newScheduler(notAnExe, 1)
      defer: scheduler.shutdown()
      let first = scheduler.add(doneDeck)
      let second = scheduler.add(doneDeck)
      for runId in [first, second]:
        let run = scheduler.store[runId]
        check (run.state, run.startedAt, run.exitCode, run.trnrunStatus, run.succeeded) ==
          (ssFinished, none(string), none(int), some(stError), some(false))
        check run.error.get().len > 0
      check scheduler.running.len == 0
      check scheduler.queue.len == 0

    test "queues runs beyond maxConcurrent and starts them as runs finish":
      let
        scheduler = newScheduler(trnrun, 1)
        firstDeck = createDeck(testDirectory, "gate-first.dck")
        secondDeck = createDeck(testDirectory, "gate-second.dck")
      defer: scheduler.shutdown()

      let
        first = scheduler.add(firstDeck)
        second = scheduler.add(secondDeck)
        third = scheduler.add(doneDeck)
      check scheduler.stateOf(first) == ssRunning
      check scheduler.stateOf(second) == ssQueued
      check scheduler.stateOf(third) == ssQueued

      release(firstDeck)
      scheduler.waitFor(first, ssFinished)
      check scheduler.stateOf(second) == ssRunning
      check scheduler.stateOf(third) == ssQueued

      release(secondDeck)
      scheduler.waitFor(third, ssFinished)
      check scheduler.store[second].succeeded == some(true)

    test "keeps waiting runs QUEUED and starts at most maxConcurrent":
      let scheduler = newScheduler(trnrun, 2)
      defer: scheduler.shutdown()

      var runIds: seq[int] = @[]
      for _ in 1..5:
        runIds.add(scheduler.add(doneDeck))
      check scheduler.running.len == 2
      check scheduler.queue.len == 3
      check runIds.countIt(scheduler.stateOf(it) == ssQueued) == 3
      for runId in runIds:
        scheduler.waitFor(runId, ssFinished)
        check scheduler.running.len <= 2
      check scheduler.running.len == 0
      check scheduler.queue.len == 0
      check runIds.countIt(scheduler.stateOf(it) == ssQueued) == 0
      for runId in runIds:
        check scheduler.store[runId].succeeded == some(true)

    test "release deletes a finished run only, and a released run is unknown":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()
      let done = scheduler.add(doneDeck)
      let queued = scheduler.add(doneDeck)
      expect InputError:
        scheduler.release(queued)
      scheduler.waitFor(queued, ssFinished)
      scheduler.release(done)
      scheduler.release(done)
      check done notin scheduler.store
      check queued in scheduler.store
      expect InputError:
        scheduler.cancel(done)

    test "cancel finishes a queued run at once, without starting it, and keeps the queue order":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-cancel-queued.dck")
      defer: scheduler.shutdown()

      discard scheduler.add(deckFile)
      let second = scheduler.add(doneDeck)
      let third = scheduler.add(doneDeck)
      scheduler.cancel(second)
      let run = scheduler.store[second]
      check (run.state, run.trnrunStatus, run.trnrunMessage, run.error, run.exitCode,
        run.startedAt, run.succeeded) == (ssFinished, some(stCancelled), some("Not started"),
        some("Not started: cancelled by the client"), none(int), none(string), some(false))
      check scheduler.queue.len == 1
      check scheduler.queue.peekFirst().runId == third

      release(deckFile)
      scheduler.waitFor(third, ssFinished)
      check scheduler.store[third].succeeded == some(true)

    test "cancel kills a running run, then frees its slot for the next queued run":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-cancel-running.dck")
      defer: scheduler.shutdown()

      let running = scheduler.add(deckFile)
      let next = scheduler.add(doneDeck)
      scheduler.cancel(running)
      scheduler.cancel(running) # Repeating it before the exit is applied changes nothing.
      check scheduler.stateOf(running) == ssRunning # Finished only once its exit is applied.

      scheduler.waitFor(running, ssFinished)
      let run = scheduler.store[running]
      check (run.trnrunStatus, run.trnrunMessage, run.error, run.exitCode, run.startedAt.isSome,
        run.succeeded) == (some(stCancelled), some("Interrupted"),
        some("Interrupted: cancelled by the client"), none(int), true, some(false))
      check not fileExists(deckFile.changeFileExt("released"))
      check running notin scheduler.running

      scheduler.waitFor(next, ssFinished)
      check scheduler.store[next].succeeded == some(true)
      check scheduler.running.len == 0

    test "cancel leaves finished runs unchanged and rejects unknown runIds":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()

      let done = scheduler.add(doneDeck)
      scheduler.waitFor(done, ssFinished)
      let finished = scheduler.store[done]
      scheduler.cancel(done)
      check scheduler.store[done] == finished

      expect InputError:
        scheduler.cancel(99)

    test "cancel keeps the real outcome of a run that exited before its exit is applied":
      let scheduler = newScheduler(trnrun, 1)
      defer: scheduler.shutdown()

      let done = scheduler.add(doneDeck)
      while scheduler.running[done].process.running:
        sleep(10)
      scheduler.cancel(done)
      scheduler.waitFor(done, ssFinished)
      let run = scheduler.store[done]
      check (run.trnrunStatus, run.exitCode, run.error, run.succeeded) ==
        (some(stDone), some(0), none(string), some(true))

    test "a waiting add replies once its run reaches the state, or a later one":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-waiting.dck")
      defer: scheduler.shutdown()

      let running = scheduler.add(deckFile, waitFor = ssRunning, replyId = "1")
      var replies = scheduler.parsedReplies()
      check replies.len == 1
      check replies[0]["id"] == %1
      check replies[0]["ok"] == %true
      check replies[0]["runId"] == %running
      check replies[0]["run"]["state"] == %"RUNNING"

      let finished = scheduler.add(doneDeck, waitFor = ssFinished, replyId = "\"f\"")
      let cancelled = scheduler.add(doneDeck, waitFor = ssRunning, replyId = "3")
      check scheduler.parsedReplies().len == 0
      scheduler.cancel(cancelled) # A later state answers a RUNNING wait.
      replies = scheduler.parsedReplies()
      check replies.mapIt((it["id"], it["run"]["state"], it["run"]["trnrunStatus"])) ==
        @[(%3, %"FINISHED", %"CANCELLED")]

      release(deckFile)
      scheduler.waitFor(finished, ssRunning)
      check scheduler.parsedReplies().len == 0 # Waits for FINISHED.
      scheduler.waitFor(finished, ssFinished)
      replies = scheduler.parsedReplies()
      check replies.mapIt((it["id"], it["runId"], it["run"]["succeeded"])) ==
        @[(%"f", %finished, %true)]

    test "a waiting add of a run cancelled by shutdown still gets its reply":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-waiting-shutdown.dck")
      defer: scheduler.shutdown()
      let running = scheduler.add(deckFile, waitFor = ssFinished, replyId = "1")
      discard scheduler.add(doneDeck, waitFor = ssRunning, replyId = "2")
      scheduler.requestShutdown()
      var replies = scheduler.parsedReplies()
      check replies.mapIt((it["id"], it["run"]["error"])) ==
        @[(%2, %"Not started: the daemon shut down")]
      scheduler.requestShutdown(cancelRunning = true)
      scheduler.waitFor(running, ssFinished)
      replies = scheduler.parsedReplies()
      check replies.mapIt((it["id"], it["run"]["error"])) ==
        @[(%1, %"Interrupted: the daemon shut down")]

    test "shutdown cancels queued runs, waits for running ones, and is idempotent":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-shutdown.dck")

      let running = scheduler.add(deckFile)
      let queued = scheduler.add(doneDeck)
      release(deckFile)
      scheduler.shutdown()
      check scheduler.running.len == 0

      check (scheduler.store[running].state, scheduler.store[running].succeeded) ==
        (ssFinished, some(true))
      let run = scheduler.store[queued]
      check (run.state, run.trnrunStatus, run.trnrunMessage, run.exitCode, run.error) ==
        (ssFinished, some(stCancelled), some("Not started"), none(int),
          some("Not started: the daemon shut down"))

      expect InputError:
        discard scheduler.add(doneDeck)
      expect ValueError:
        scheduler.cancel(running)
      scheduler.shutdown()

    test "a requested shutdown keeps serving cancel, rejects add, and can kill running runs":
      let
        scheduler = newScheduler(trnrun, 2)
        firstDeck = createDeck(testDirectory, "gate-shutdown-first.dck")
        secondDeck = createDeck(testDirectory, "gate-shutdown-second.dck")
      defer: scheduler.shutdown()

      let first = scheduler.add(firstDeck)
      let second = scheduler.add(secondDeck)
      scheduler.requestShutdown()
      check not scheduler.isDone
      expect InputError:
        discard scheduler.add(doneDeck)

      scheduler.cancel(first)
      scheduler.waitFor(first, ssFinished)
      check scheduler.store[first].error == some("Interrupted: cancelled by the client")
      check not scheduler.isDone

      scheduler.requestShutdown(cancelRunning = true)
      scheduler.waitFor(second, ssFinished)
      let run = scheduler.store[second]
      check (run.trnrunStatus, run.error, run.succeeded) ==
        (some(stCancelled), some("Interrupted: the daemon shut down"), some(false))
      check scheduler.isDone
      for deckFile in [firstDeck, secondDeck]:
        check not fileExists(deckFile.changeFileExt("released"))

    test "abandon kills TRNRun and drops waiting adds without replying":
      let
        scheduler = newScheduler(trnrun, 1)
        deckFile = createDeck(testDirectory, "gate-abandon.dck")

      discard scheduler.add(deckFile, waitFor = ssFinished, replyId = "1")
      discard scheduler.add(doneDeck)
      scheduler.abandon()
      check scheduler.running.len == 0
      check scheduler.queue.len == 0
      expect InputError:
        discard scheduler.add(doneDeck)
      scheduler.abandon()
      scheduler.shutdown()

      scheduler.pool.shutdown() # TRNRun was killed, so every worker is idle again.
      check scheduler.takeReplies().len == 0
      check not fileExists(deckFile.changeFileExt("released"))

runTests()
