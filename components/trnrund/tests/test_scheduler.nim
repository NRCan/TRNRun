import std/[json, os, unittest]
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
        (runId: "colon", deckFile: doneDeck, trnrunArgs: @["--deckFile:other.dck"]),
        (runId: "equals", deckFile: doneDeck, trnrunArgs: @["--deckFile=other.dck"]),
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

    test "holds only dispatched runs in memory and reads every run from the database":
      let scheduler = newScheduler(trnrun, 2, testDirectory / "memory.sqlite3")
      defer: scheduler.shutdown()

      check "unknown" notin scheduler.database

      let runIds = ["a", "b", "c", "d", "e"]
      for runId in runIds:
        scheduler.add(runId, doneDeck)
      check scheduler.running.len == 2
      check scheduler.queue.len == 3
      for runId in runIds:
        scheduler.waitFor(runId, ssFinished)
        check scheduler.running.len <= 2
      check scheduler.running.len == 0
      check scheduler.queue.len == 0
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
        let running = scheduler.running["run"]
        check saved("run", "state, started_at, notices") ==
          @["RUNNING", running.startedAt.get(), $running.notices]
        release(deckFile)
        scheduler.waitFor("run", ssFinished)
        check "run" notin scheduler.running
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

    test "rejects a database in a missing directory":
      expect DatabaseError:
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
      check scheduler.running.len == 0

      check scheduler.columns("running", "state, succeeded") == @["FINISHED", "1"]
      check scheduler.columns("queued",
        "state, trnrun_status, trnrun_message, exit_code IS NULL, error") ==
        @["FINISHED", "CANCELLED", "Not started", "1", "Not started: the daemon shut down"]

      expect ValueError:
        scheduler.add("late", doneDeck)
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
      check scheduler.running.len == 0
      check scheduler.queue.len == 0
      expect ValueError:
        scheduler.add("late", doneDeck)
      scheduler.abandon()
      scheduler.shutdown()

      check scheduler.columns("running",
        "state, trnrun_status, trnrun_message, error, exit_code IS NULL, started_at IS NOT NULL") ==
        @["FINISHED", "CANCELLED", "Interrupted", "Interrupted: the client disconnected", "1", "1"]
      check scheduler.columns("queued", "state, error") ==
        @["FINISHED", "Not started: the client disconnected"]
      check not fileExists(path & ".lock")

      release(deckFile) # Lets TRNRun exit so the test can join the workers.
      scheduler.pool.shutdown()

runTests()
