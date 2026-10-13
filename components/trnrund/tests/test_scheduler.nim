import std/[os, strutils, unittest]
import db_connector/db_sqlite

include ../src/scheduler
import ./fake_trnrun

proc createDeck(directory, name: string): string =
  result = directory / name
  writeFile(result, "fake TRNSYS deck")

proc release(deckFile: string) =
  ## Lets a `gate` run finish.
  writeFile(deckFile.changeFileExt("release"), "")

proc columns(scheduler: Scheduler, runId, expressions: string): Row =
  ## `expressions` on the saved row of `runId`, read from the database file as a client would.
  let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
  defer: reader.close()
  reader.getRow(sql("SELECT " & expressions & " FROM runs WHERE run_id = ?"), runId)

proc queued(scheduler: Scheduler): int =
  ## Runs `QUEUED` in the database.
  let reader = db_sqlite.open(scheduler.databasePath, "", "", "")
  defer: reader.close()
  parseInt(reader.getValue(sql"SELECT count(*) FROM runs WHERE state = 'QUEUED'"))

proc stateOf(scheduler: Scheduler, runId: string): SimulationState =
  ## Saved state of `runId`.
  parseEnum[SimulationState](scheduler.columns(runId, "state")[0])

proc waitFor(scheduler: Scheduler, runId: string, state: SimulationState) =
  ## Applies worker messages until `runId` reaches at least `state`.
  while scheduler.stateOf(runId) < state:
    scheduler.apply(scheduler.inbox.recv())

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
        discard newScheduler(trnrun, 0, testDirectory / "unused.sqlite3")
      expect ValueError:
        discard newScheduler(testDirectory / "missing-trnrun.exe", 1, testDirectory / "unused.sqlite3")

    test "rejects invalid submissions without registering them":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "rejected.sqlite3")
      defer: scheduler.shutdown()
      scheduler.add("kept", doneDeck)

      let cases = [
        (runId: "", deckFile: doneDeck, trnrunArgs: newSeq[string]()),
        (runId: "kept", deckFile: doneDeck, trnrunArgs: newSeq[string]()),
        (runId: "missing", deckFile: testDirectory / "missing.dck", trnrunArgs: newSeq[string]()),
        (runId: "text", deckFile: createDeck(testDirectory, "deck.txt"), trnrunArgs: newSeq[string]()),
        (runId: "deck", deckFile: doneDeck, trnrunArgs: @["--deckFile:other.dck"]),
        (runId: "unknown", deckFile: doneDeck, trnrunArgs: @["--pollMs:50", "--watchTMP:true"]),
      ]
      for testCase in cases:
        checkpoint("runId: " & testCase.runId)
        expect ValueError:
          scheduler.add(testCase.runId, testCase.deckFile, testCase.trnrunArgs)

      check "kept" in scheduler.database
      for testCase in cases[2 .. ^1]:
        check testCase.runId notin scheduler.database

    test "runs a simulation through every state to a successful finish":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "lifecycle-states.sqlite3")
        deckFile = createDeck(testDirectory, "gate-lifecycle.dck")
      defer: scheduler.shutdown()

      scheduler.add("run", deckFile)
      check scheduler.stateOf("run") == ssAccepted

      scheduler.waitFor("run", ssRunning)
      check scheduler.stateOf("run") == ssRunning

      release(deckFile)
      scheduler.waitFor("run", ssFinished)
      check scheduler.columns("run", """trnrun_status, trnrun_message, exit_code, notices, warnings,
        succeeded, submitted_at <= started_at AND started_at <= finished_at""") ==
        @["DONE", "", "0", "2", "1", "1", "1"]

    test "finishes with an ERROR status when TRNRun fails or reports none":
      let scheduler = newScheduler(trnrun, 2, testDirectory / "errors.sqlite3")
      defer: scheduler.shutdown()
      scheduler.add("failed", createDeck(testDirectory, "failed.dck"))
      scheduler.add("silent", createDeck(testDirectory, "silent.dck"))
      scheduler.waitFor("failed", ssFinished)
      scheduler.waitFor("silent", ssFinished)

      const Outcome = "trnrun_status, trnrun_message, exit_code, succeeded"
      check scheduler.columns("failed", Outcome) == @["ERROR", "Fake failure", "1", "0"]
      check scheduler.columns("silent", Outcome) ==
        @["ERROR", "TRNRun exited without a terminal status", "0", "0"]

    test "queues runs beyond maxConcurrent and starts them as runs finish":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "queue.sqlite3")
        firstDeck = createDeck(testDirectory, "gate-first.dck")
        secondDeck = createDeck(testDirectory, "gate-second.dck")
      defer: scheduler.shutdown()

      scheduler.add("first", firstDeck)
      scheduler.add("second", secondDeck)
      scheduler.add("third", doneDeck)
      check scheduler.stateOf("first") == ssAccepted
      check scheduler.stateOf("second") == ssQueued
      check scheduler.stateOf("third") == ssQueued

      release(firstDeck)
      scheduler.waitFor("first", ssFinished)
      check scheduler.stateOf("second") in {ssAccepted, ssRunning}
      check scheduler.stateOf("third") == ssQueued

      release(secondDeck)
      scheduler.waitFor("third", ssFinished)
      check scheduler.columns("second", "succeeded") == @["1"]

    test "queues waiting runs in memory and shows them QUEUED in the database":
      let scheduler = newScheduler(trnrun, 2, testDirectory / "memory.sqlite3")
      defer: scheduler.shutdown()

      check "unknown" notin scheduler.database

      let runIds = ["a", "b", "c", "d", "e"]
      for runId in runIds:
        scheduler.add(runId, doneDeck)
      check scheduler.running == 2
      check scheduler.queue.len == 3
      check scheduler.queued == 3
      for runId in runIds:
        scheduler.waitFor(runId, ssFinished)
        check scheduler.running <= 2
      check scheduler.running == 0
      check scheduler.queue.len == 0
      check scheduler.queued == 0
      for runId in runIds:
        check scheduler.columns(runId, "succeeded") == @["1"]

    test "saves every change as it is applied, and runIds stay taken across schedulers":
      let
        path = testDirectory / "lifecycle.sqlite3"
        deckFile = createDeck(testDirectory, "gate-persist.dck")
        reader = db_sqlite.open(path, "", "", "")
      defer: reader.close()
      proc saved(runId, expressions: string): Row =
        reader.getRow(sql("SELECT " & expressions & " FROM runs WHERE run_id = ?"), runId)

      block:
        let scheduler = newScheduler(trnrun, 1, path)
        defer: scheduler.shutdown()
        scheduler.add("run", deckFile)
        scheduler.add("queued", doneDeck)
        check saved("run", "state") == @["ACCEPTED"]
        check saved("queued", "state") == @["QUEUED"]

        scheduler.waitFor("run", ssRunning)
        check saved("run", "state, started_at IS NOT NULL") == @["RUNNING", "1"]
        release(deckFile)
        scheduler.waitFor("run", ssFinished)
        check saved("run", "succeeded") == @["1"]
        let logs = reader.getAllRows(sql"SELECT message FROM logs WHERE run_id = 'run' ORDER BY log_id")
        check logs.len == 3
        check logs[2][0] == "third"
        check saved("queued", "state")[0] in ["ACCEPTED", "RUNNING", "FINISHED"]

      let scheduler = newScheduler(trnrun, 1, path)
      defer: scheduler.shutdown()
      for runId in ["run", "queued"]:
        expect ValueError:
          scheduler.add(runId, doneDeck)
      check reader.getValue(sql"SELECT count(*) FROM runs") == "2"
      check reader.getValue(sql"SELECT count(*) FROM logs") == "6"

    test "cancel finishes a queued run at once, without starting it, and keeps the queue order":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "cancel-queued.sqlite3")
        deckFile = createDeck(testDirectory, "gate-cancel-queued.dck")
      defer: scheduler.shutdown()

      scheduler.add("first", deckFile)
      scheduler.add("second", doneDeck)
      scheduler.add("third", doneDeck)
      scheduler.cancel("second")
      check scheduler.columns("second",
        "state, trnrun_status, trnrun_message, error, exit_code IS NULL, started_at IS NULL, succeeded") ==
        @["FINISHED", "CANCELLED", "Not started", "Not started: cancelled by the client", "1", "1", "0"]
      check scheduler.queue.len == 1
      check scheduler.queue.peekFirst().runId == "third"

      release(deckFile)
      scheduler.waitFor("third", ssFinished)
      check scheduler.columns("third", "succeeded") == @["1"]

    test "cancel kills a running run, then frees its worker for the next queued run":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "cancel-running.sqlite3")
        deckFile = createDeck(testDirectory, "gate-cancel-running.dck")
      defer: scheduler.shutdown()

      scheduler.add("running", deckFile)
      scheduler.add("next", doneDeck)
      scheduler.waitFor("running", ssRunning)
      scheduler.cancel("running")
      scheduler.cancel("running") # Repeating it before the exit is applied changes nothing.
      check scheduler.stateOf("running") == ssRunning # Finished only once its exit is applied.

      scheduler.waitFor("running", ssFinished)
      check scheduler.columns("running",
        "trnrun_status, trnrun_message, error, exit_code IS NULL, started_at IS NOT NULL, succeeded") ==
        @["CANCELLED", "Interrupted", "Interrupted: cancelled by the client", "1", "1", "0"]
      check not fileExists(deckFile.changeFileExt("released"))
      check "running" notin scheduler.dispatched

      scheduler.waitFor("next", ssFinished)
      check scheduler.columns("next", "succeeded") == @["1"]
      check scheduler.running == 0

    test "cancel of a just-dispatched run reports whether its TRNRun had started":
      let
        scheduler = newScheduler(trnrun, 1, testDirectory / "cancel-accepted.sqlite3")
        deckFile = createDeck(testDirectory, "gate-cancel-accepted.dck")
      defer: scheduler.shutdown()

      scheduler.add("accepted", deckFile)
      scheduler.cancel("accepted") # Races the worker's launch; either outcome is consistent.
      scheduler.waitFor("accepted", ssFinished)
      check scheduler.columns("accepted", "trnrun_status, succeeded") == @["CANCELLED", "0"]
      check scheduler.columns("accepted",
        "(error = 'Not started: cancelled by the client') = (started_at IS NULL)") == @["1"]
      check not fileExists(deckFile.changeFileExt("released"))

    test "cancel leaves finished runs unchanged and rejects unknown runIds":
      let scheduler = newScheduler(trnrun, 1, testDirectory / "cancel-finished.sqlite3")
      defer: scheduler.shutdown()

      scheduler.add("done", doneDeck)
      scheduler.waitFor("done", ssFinished)
      let finished = scheduler.columns("done", "*")
      scheduler.cancel("done")
      check scheduler.columns("done", "*") == finished

      expect ValueError:
        scheduler.cancel("missing")

    test "rejects a database in a missing directory":
      expect DbError:
        discard newScheduler(trnrun, 1, testDirectory / "missing" / "runs.sqlite3")

    test "shutdown cancels queued runs, waits for running ones, and is idempotent":
      let
        path = testDirectory / "shutdown.sqlite3"
        scheduler = newScheduler(trnrun, 1, path)
        deckFile = createDeck(testDirectory, "gate-shutdown.dck")

      scheduler.add("running", deckFile)
      scheduler.add("queued", doneDeck)
      release(deckFile)
      scheduler.shutdown()
      check scheduler.running == 0

      check scheduler.columns("running", "state, succeeded") == @["FINISHED", "1"]
      check scheduler.columns("queued",
        "state, trnrun_status, trnrun_message, exit_code IS NULL, error") ==
        @["FINISHED", "CANCELLED", "Not started", "1", "Not started: the daemon shut down"]

      expect ValueError:
        scheduler.add("late", doneDeck)
      expect ValueError:
        scheduler.cancel("running")
      scheduler.shutdown()

    test "abandon finishes queued and running runs as interrupted without waiting":
      let
        path = testDirectory / "abandon.sqlite3"
        scheduler = newScheduler(trnrun, 1, path)
        deckFile = createDeck(testDirectory, "gate-abandon.dck")

      scheduler.add("running", deckFile)
      scheduler.add("queued", doneDeck)
      scheduler.waitFor("running", ssRunning)
      scheduler.abandon() # Returns although the gate keeps TRNRun running.
      check scheduler.running == 0
      expect ValueError:
        scheduler.add("late", doneDeck)
      scheduler.abandon()
      scheduler.shutdown()

      check scheduler.columns("running",
        "state, trnrun_status, trnrun_message, error, exit_code IS NULL, started_at IS NOT NULL") ==
        @["FINISHED", "CANCELLED", "Interrupted", "Interrupted: the client disconnected", "1", "1"]
      check scheduler.columns("queued", "state, error") ==
        @["FINISHED", "Not started: the client disconnected"]
      check scheduler.queued == 0
      check not fileExists(path & ".lock")

      release(deckFile) # Lets TRNRun exit so the test can join the workers.
      scheduler.pool.shutdown()

runTests()
