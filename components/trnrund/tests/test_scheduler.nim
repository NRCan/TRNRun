import std/[os, strutils, unittest]
import db_connector/db_sqlite

include ../src/scheduler
import ../src/job
import ./[fake_deck, fake_trnrun]

proc release(deckFile: string) =
  ## Lets a `gate` run finish.
  writeFile(deckFile.changeFileExt("release"), "")

proc columns(scheduler: Scheduler, runId: int, expressions: string): Row =
  ## `expressions` on the saved row of `runId`, read from the database file as a client would.
  let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
  defer: reader.close()
  reader.getRow(sql("SELECT " & expressions & " FROM runs WHERE run_id = ?"), runId)

proc queued(scheduler: Scheduler): int =
  ## Runs `QUEUED` in the database.
  let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
  defer: reader.close()
  parseInt(reader.getValue(sql"SELECT count(*) FROM runs WHERE state = 'QUEUED'"))

proc stateOf(scheduler: Scheduler, runId: int): SimulationState =
  ## Saved state of `runId`.
  parseEnum[SimulationState](scheduler.columns(runId, "state")[0])

proc step(scheduler: Scheduler) =
  ## Applies the next batch of worker messages, as the daemon does.
  let messages = scheduler.receive()
  scheduler.atomically:
    for message in messages:
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
        discard newScheduler(trnrun, 0, testDirectory / "unused.sqlite3")
      expect InputError:
        discard newScheduler(testDirectory / "missing-trnrun.exe", 1,
          testDirectory / "unused.sqlite3")

    test "numbers runs and rejects invalid submissions without saving them":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "rejected.sqlite3")
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
      check 3 notin scheduler
      check scheduler.columns(2, "label") == @["second"]

    test "launches a run at once and finishes it successfully":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "lifecycle-states.sqlite3")
        deckFile = createDeck(testDirectory, "gate-lifecycle.dck")
      defer: scheduler.shutdown()

      let runId = scheduler.add(deckFile)
      check scheduler.stateOf(runId) == ssRunning
      check scheduler.columns(runId, "started_at IS NOT NULL") == @["1"]

      release(deckFile)
      scheduler.waitFor(runId, ssFinished)
      check scheduler.columns(runId, """trnrun_status, trnrun_message, exit_code, notices, warnings,
        succeeded, submitted_at <= started_at AND started_at <= finished_at""") ==
        @["DONE", "", "0", "2", "1", "1", "1"]

    test "finishes with an ERROR status when TRNRun fails or reports none":
      let scheduler = newScheduler(trnrun, 2, testDirectory / "errors.sqlite3")
      defer: scheduler.shutdown()
      let
        failed = scheduler.add(createDeck(testDirectory, "failed.dck"))
        silent = scheduler.add(createDeck(testDirectory, "silent.dck"))
      scheduler.waitFor(failed, ssFinished)
      scheduler.waitFor(silent, ssFinished)

      const Outcome = "trnrun_status, trnrun_message, exit_code, succeeded"
      check scheduler.columns(failed, Outcome) == @["ERROR", "Fake failure", "1", "0"]
      check scheduler.columns(silent, Outcome) ==
        @["ERROR", "TRNRun exited without a terminal status", "0", "0"]

    test "a run whose TRNRun cannot start finishes from QUEUED and frees its slot":
      let
        notAnExe = createDeck(testDirectory, "not-an-exe.exe")
        scheduler = newScheduler(notAnExe, 1, testDirectory / "unlaunched.sqlite3")
      defer: scheduler.shutdown()
      let first = scheduler.add(doneDeck)
      let second = scheduler.add(doneDeck)
      for runId in [first, second]:
        check scheduler.columns(runId, "state, started_at IS NULL, exit_code IS NULL, " &
          "trnrun_status, error != '', succeeded") == @["FINISHED", "1", "1", "ERROR", "1", "0"]
      check scheduler.running.len == 0
      check scheduler.queue.len == 0

    test "queues runs beyond maxConcurrent and starts them as runs finish":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "queue.sqlite3")
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
      check scheduler.columns(second, "succeeded") == @["1"]

    test "queues waiting runs in memory and shows them QUEUED in the database":
      let scheduler = newScheduler(trnrun, 2, testDirectory / "memory.sqlite3")
      defer: scheduler.shutdown()

      var runIds: seq[int] = @[]
      for _ in 1..5:
        runIds.add(scheduler.add(doneDeck))
      check scheduler.running.len == 2
      check scheduler.queue.len == 3
      check scheduler.queued == 3
      for runId in runIds:
        scheduler.waitFor(runId, ssFinished)
        check scheduler.running.len <= 2
      check scheduler.running.len == 0
      check scheduler.queue.len == 0
      check scheduler.queued == 0
      for runId in runIds:
        check scheduler.columns(runId, "succeeded") == @["1"]

    test "a batch of saves is visible only once it commits":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "batch.sqlite3")
        reader = db_sqlite.open(scheduler.databasePath, "", "", "")
      defer:
        reader.close()
        scheduler.shutdown()
      scheduler.atomically:
        discard scheduler.add(doneDeck)
        check reader.getValue(sql"SELECT count(*) FROM runs") == "0"
      check reader.getValue(sql"SELECT count(*) FROM runs") == "1"

    test "saves every change, and run numbers continue in a new session":
      let
        path = testDirectory / "lifecycle.sqlite3"
        deckFile = createDeck(testDirectory, "gate-persist.dck")
        reader = db_sqlite.open(path, "", "", "")
      defer: reader.close()
      proc saved(runId: int, expressions: string): Row =
        ## `expressions` on the saved row of `runId`.
        reader.getRow(sql("SELECT " & expressions & " FROM runs WHERE run_id = ?"), runId)

      block:
        let scheduler = newScheduler(trnrun, 1, path)
        defer: scheduler.shutdown()
        let run = scheduler.add(deckFile)
        let queued = scheduler.add(doneDeck)
        check saved(run, "state, started_at IS NOT NULL, session_id") == @["RUNNING", "1", "1"]
        check saved(queued, "state") == @["QUEUED"]

        release(deckFile)
        scheduler.waitFor(run, ssFinished)
        check saved(run, "succeeded") == @["1"]
        let logs = reader.getAllRows(sql"SELECT message FROM logs WHERE run_id = 1 ORDER BY log_id")
        check logs.len == 3
        check logs[2][0] == "third"

      let scheduler = newScheduler(trnrun, 1, path)
      defer: scheduler.shutdown()
      let next = scheduler.add(doneDeck)
      check next == 3
      check saved(next, "session_id") == @["2"]
      check reader.getValue(sql"SELECT count(*) FROM sessions") == "2"

    test "cancel finishes a queued run at once, without starting it, and keeps the queue order":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "cancel-queued.sqlite3")
        deckFile = createDeck(testDirectory, "gate-cancel-queued.dck")
      defer: scheduler.shutdown()

      discard scheduler.add(deckFile)
      let second = scheduler.add(doneDeck)
      let third = scheduler.add(doneDeck)
      scheduler.cancel(second)
      let expressions = "state, trnrun_status, trnrun_message, error, exit_code IS NULL, " &
        "started_at IS NULL, succeeded"
      check scheduler.columns(second, expressions) == @["FINISHED", "CANCELLED", "Not started",
        "Not started: cancelled by the client", "1", "1", "0"]
      check scheduler.queue.len == 1
      check scheduler.queue.peekFirst().runId == third

      release(deckFile)
      scheduler.waitFor(third, ssFinished)
      check scheduler.columns(third, "succeeded") == @["1"]

    test "cancel kills a running run, then frees its slot for the next queued run":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "cancel-running.sqlite3")
        deckFile = createDeck(testDirectory, "gate-cancel-running.dck")
      defer: scheduler.shutdown()

      let running = scheduler.add(deckFile)
      let next = scheduler.add(doneDeck)
      scheduler.cancel(running)
      scheduler.cancel(running) # Repeating it before the exit is applied changes nothing.
      check scheduler.stateOf(running) == ssRunning # Finished only once its exit is applied.

      scheduler.waitFor(running, ssFinished)
      let expressions = "trnrun_status, trnrun_message, error, exit_code IS NULL, " &
        "started_at IS NOT NULL, succeeded"
      check scheduler.columns(running, expressions) ==
        @["CANCELLED", "Interrupted", "Interrupted: cancelled by the client", "1", "1", "0"]
      check not fileExists(deckFile.changeFileExt("released"))
      check running notin scheduler.running

      scheduler.waitFor(next, ssFinished)
      check scheduler.columns(next, "succeeded") == @["1"]
      check scheduler.running.len == 0

    test "cancel leaves finished runs unchanged and rejects unknown runIds":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "cancel-finished.sqlite3")
      defer: scheduler.shutdown()

      let done = scheduler.add(doneDeck)
      scheduler.waitFor(done, ssFinished)
      let finished = scheduler.columns(done, "*")
      scheduler.cancel(done)
      check scheduler.columns(done, "*") == finished

      expect InputError:
        scheduler.cancel(99)

    test "cancel keeps the real outcome of a run that exited before its exit is applied":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "cancel-exited.sqlite3")
      defer: scheduler.shutdown()

      let done = scheduler.add(doneDeck)
      while scheduler.running[done].process.running:
        sleep(10)
      scheduler.cancel(done)
      scheduler.waitFor(done, ssFinished)
      check scheduler.columns(done, "trnrun_status, exit_code, error IS NULL, succeeded") ==
        @["DONE", "0", "1", "1"]

    test "rejects a database in a missing directory":
      expect DbError:
        discard newScheduler(trnrun, 1, testDirectory / "missing" / "runs.sqlite3")

    test "shutdown cancels queued runs, waits for running ones, and is idempotent":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "shutdown.sqlite3")
        deckFile = createDeck(testDirectory, "gate-shutdown.dck")

      let running = scheduler.add(deckFile)
      let queued = scheduler.add(doneDeck)
      release(deckFile)
      scheduler.shutdown()
      check scheduler.running.len == 0

      check scheduler.columns(running, "state, succeeded") == @["FINISHED", "1"]
      check scheduler.columns(queued,
        "state, trnrun_status, trnrun_message, exit_code IS NULL, error") ==
        @["FINISHED", "CANCELLED", "Not started", "1", "Not started: the daemon shut down"]

      expect InputError:
        discard scheduler.add(doneDeck)
      expect ValueError:
        scheduler.cancel(running)
      scheduler.shutdown()

    test "a requested shutdown keeps serving cancel, rejects add, and can kill running runs":
      let
        scheduler = newScheduler(trnrun, 2, testDirectory / "shutdown-requested.sqlite3")
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
      check scheduler.columns(first, "error") == @["Interrupted: cancelled by the client"]
      check not scheduler.isDone

      scheduler.requestShutdown(cancelRunning = true)
      scheduler.waitFor(second, ssFinished)
      check scheduler.columns(second, "trnrun_status, error, succeeded") ==
        @["CANCELLED", "Interrupted: the daemon shut down", "0"]
      check scheduler.isDone
      for deckFile in [firstDeck, secondDeck]:
        check not fileExists(deckFile.changeFileExt("released"))

    test "abandon finishes queued and running runs as interrupted and kills TRNRun":
      let
        path = testDirectory / "abandon.sqlite3"
        scheduler = newScheduler(trnrun, 1, path)
        deckFile = createDeck(testDirectory, "gate-abandon.dck")

      let running = scheduler.add(deckFile)
      let queued = scheduler.add(doneDeck)
      scheduler.abandon()
      check scheduler.running.len == 0
      expect InputError:
        discard scheduler.add(doneDeck)
      scheduler.abandon()
      scheduler.shutdown()

      check scheduler.columns(running,
        "state, trnrun_status, trnrun_message, error, exit_code IS NULL, started_at IS NOT NULL") ==
        @["FINISHED", "CANCELLED", "Interrupted", "Interrupted: the client disconnected", "1", "1"]
      check scheduler.columns(queued, "state, error") ==
        @["FINISHED", "Not started: the client disconnected"]
      check scheduler.queued == 0
      check not fileExists(path & ".lock")

      scheduler.pool.shutdown() # TRNRun was killed, so every worker is idle again.
      check not fileExists(deckFile.changeFileExt("released"))

runTests()
