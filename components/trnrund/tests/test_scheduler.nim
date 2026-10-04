import std/[os, tempfiles, times, unittest]
# Included rather than imported so tests can apply messages without blocking.
include ../src/scheduler

let fakeTrnrun = getAppDir() / "fake_trnrun.exe"
if not fileExists(fakeTrnrun):
  quit("Compile fake_trnrun.exe beside the test executable first", 2)

proc deck(directory, name: string, mode: string = "fast"): string =
  result = directory / (name & ".dck")
  writeFile(result, mode)

proc releaseDeck(path: string) =
  writeFile(path & ".release", "")

proc applyAvailable(scheduler: Scheduler) =
  ## Applies every message already in the inbox without waiting.
  while true:
    let (available, message) = scheduler.inbox.tryRecv()
    if not available:
      break
    scheduler.apply(message)

proc wait(scheduler: Scheduler) =
  ## Applies messages until all work finishes.
  while scheduler.queue.len > 0 or scheduler.runningCount > 0:
    scheduler.apply(scheduler.inbox.recv())

template pollUntil(scheduler: Scheduler, condition: untyped, failure: string) =
  ## Applies scheduler messages until `condition` holds, failing after 4 s.
  let deadline = epochTime() + 4
  while true:
    scheduler.applyAvailable()
    if condition:
      break
    if epochTime() > deadline:
      raise newException(AssertionDefect, failure)
    sleep(5)

proc awaitReady(scheduler: Scheduler, path: string) =
  scheduler.pollUntil(fileExists(path & ".ready"), "TRNRun did not become ready: " & path)

proc awaitStatus(scheduler: Scheduler, runId: string, status: SimStatus) =
  scheduler.pollUntil(
    scheduler[runId].status.get(StatusEvent()).status == status,
    "TRNRun did not report expected status",
  )

proc awaitFinished(scheduler: Scheduler, runId: string) =
  scheduler.pollUntil(scheduler[runId].state == ssFinished, "Run did not finish: " & runId)

proc runIds(scheduler: Scheduler): seq[string] =
  result = @[]
  for simulation in scheduler:
    result.add(simulation.runId)

proc checkLaunchFailed(simulation: Simulation) =
  check simulation.state == ssFinished
  check simulation.exitCode.isNone
  check simulation.error.len > 0
  check simulation.status.get().status == statusError
  check not simulation.succeeded()

suite "Scheduler":
  test "validates concurrency and TRNRun, and shuts down idempotently":
    expect ValueError:
      discard newScheduler(fakeTrnrun, 0)
    expect ValueError:
      discard newScheduler(getAppDir() / "missing.exe", 1)
    let scheduler = newScheduler(fakeTrnrun, 1)
    scheduler.shutdown()
    scheduler.shutdown()

  test "invalid submissions do not change the registry":
    let directory = createTempDir("trnrund-validation-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    try:
      let path = deck(directory, "valid")
      expect ValueError:
        scheduler.add("", path)
      expect ValueError:
        scheduler.add("missing", directory / "missing.dck")
      let unsupported = directory / "invalid.txt"
      writeFile(unsupported, "")
      expect ValueError:
        scheduler.add("extension", unsupported)
      for runId in ["missing", "extension"]:
        expect KeyError:
          discard scheduler[runId]

      scheduler.add("valid", path)
      expect ValueError:
        scheduler.add("valid", path)
      scheduler.wait()
      check scheduler["valid"].succeeded()
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "a full pool leaves work queued and dispatches FIFO after exit":
    let directory = createTempDir("trnrund-fifo-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let first = deck(directory, "first", "done-first")
    let second = deck(directory, "second", "hold")
    let third = deck(directory, "third")
    try:
      scheduler.add("first", first)
      scheduler.add("second", second)
      scheduler.add("third", third)
      check scheduler["first"].state == ssAccepted
      check scheduler["second"].state == ssQueued
      check scheduler["third"].state == ssQueued

      scheduler.awaitReady(first)
      scheduler.awaitStatus("first", statusDone)
      check scheduler["first"].state == ssRunning
      check not scheduler["first"].succeeded()
      check scheduler["second"].state == ssQueued
      check not fileExists(second & ".ready")

      releaseDeck(first)
      scheduler.awaitFinished("first")
      check scheduler["first"].succeeded()
      check scheduler["second"].state == ssAccepted
      check scheduler["third"].state == ssQueued
      scheduler.awaitReady(second)
      releaseDeck(second)
      scheduler.wait()
      for runId in ["first", "second", "third"]:
        check scheduler[runId].succeeded()
    finally:
      releaseDeck(first)
      releaseDeck(second)
      scheduler.shutdown()
      removeDir(directory)

  test "multiple slots run concurrently without exceeding the configured limit":
    let directory = createTempDir("trnrund-concurrent-", "")
    let scheduler = newScheduler(fakeTrnrun, 2)
    let first = deck(directory, "first", "hold")
    let second = deck(directory, "second", "hold")
    let third = deck(directory, "third")
    try:
      scheduler.add("first", first)
      scheduler.add("second", second)
      scheduler.add("third", third)
      scheduler.awaitReady(first)
      scheduler.awaitReady(second)
      check scheduler["third"].state == ssQueued
      check not fileExists(third & ".ready")
      releaseDeck(first)
      scheduler.awaitFinished("third")
      check scheduler["third"].succeeded()
      check scheduler["second"].state != ssFinished
      releaseDeck(second)
      scheduler.wait()
    finally:
      releaseDeck(first)
      releaseDeck(second)
      scheduler.shutdown()
      removeDir(directory)

  test "a failed run finishes and frees capacity for the next queued run":
    let directory = createTempDir("trnrund-failure-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let first = deck(directory, "first", "hold")
    let removed = deck(directory, "removed")
    try:
      scheduler.add("first", first)
      scheduler.add("removed", removed)
      scheduler.add("last", deck(directory, "last"))
      removeFile(removed)
      releaseDeck(first)
      scheduler.wait()
      # TRNRun still launches and reports the missing deck itself.
      check scheduler["removed"].state == ssFinished
      check scheduler["removed"].status.get().status == statusError
      check not scheduler["removed"].succeeded()
      check scheduler["last"].succeeded()
    finally:
      releaseDeck(first)
      scheduler.shutdown()
      removeDir(directory)

  test "an invalid TRNRun executable fails every run at launch":
    let directory = createTempDir("trnrund-invalid-", "")
    let invalidTrnrun = directory / "invalid.exe"
    writeFile(invalidTrnrun, "not an executable")
    let scheduler = newScheduler(invalidTrnrun, 1)
    try:
      scheduler.add("first", deck(directory, "first"))
      scheduler.add("second", deck(directory, "second"))
      scheduler.wait()
      for runId in ["first", "second"]:
        scheduler[runId].checkLaunchFailed()
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "a stored simulation is a copy, independent of the scheduler's":
    let directory = createTempDir("trnrund-copy-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let path = deck(directory, "first")
    try:
      var args = @["--test"]
      scheduler.add("first", path, args)
      args[0] = "caller change"
      scheduler.wait()
      var copy = scheduler["first"]
      check copy.notices == 1
      copy.trnrunArgs[0][0] = 'X'
      copy.status.get().message = "changed"
      copy.logs[0].message = some("changed")
      copy.logs.add(LogEvent(severity: Fatal))

      let original = scheduler["first"]
      check original.trnrunArgs == @["--test"]
      check original.status.get().message == "Completed"
      check original.logs.len == 1
      check original.logs[0].message == some("Started")
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "remove forgets finished simulations only":
    let directory = createTempDir("trnrund-remove-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let held = deck(directory, "held", "hold")
    let fast = deck(directory, "fast")
    try:
      scheduler.add("held", held)
      scheduler.add("fast", fast)
      expect ValueError:
        scheduler.remove("held")
      expect ValueError:
        scheduler.remove("fast")
      expect KeyError:
        scheduler.remove("unknown")

      releaseDeck(held)
      scheduler.wait()
      check scheduler.runIds == @["held", "fast"]
      scheduler.remove("held")
      expect KeyError:
        discard scheduler["held"]
      check scheduler["fast"].succeeded()
      check scheduler.runIds == @["fast"]

      # A removed runId can be submitted again, as a new submission.
      scheduler.add("held", fast)
      scheduler.awaitFinished("held")
      check scheduler["held"].succeeded()
      check scheduler.runIds == @["fast", "held"]
    finally:
      releaseDeck(held)
      scheduler.shutdown()
      removeDir(directory)

  test "iteration follows submission order, not hash order":
    let directory = createTempDir("trnrund-order-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    try:
      let path = deck(directory, "fast")
      var expected: seq[string] = @[]
      for index in countdown(49, 0):
        expected.add("run" & $index)
        scheduler.add(expected[^1], path)
      scheduler.shutdown() # Cancels the queued runs, so all finish at once.
      check scheduler.runIds == expected

      for runId in ["run30", "run10", "run49"]:
        scheduler.remove(runId)
        expected.delete(expected.find(runId))
      check scheduler.runIds == expected
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "shutdown cancels queued work but finishes running work":
    let directory = createTempDir("trnrund-shutdown-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let held = deck(directory, "held", "hold")
    try:
      scheduler.add("held", held)
      scheduler.add("queued", deck(directory, "queued"))
      scheduler.awaitReady(held)
      # The held run's exit is not processed yet, so "queued" is still queued.
      releaseDeck(held)
      scheduler.shutdown()
      check scheduler["held"].succeeded()
      let queued = scheduler["queued"]
      check queued.state == ssFinished
      check queued.status.get().status == statusCancelled
      check queued.exitCode.isNone
      check queued.error == "Not started: the daemon shut down"
      check not fileExists(directory / "queued.dck.ready")
      expect ValueError:
        scheduler.add("late", held)
    finally:
      releaseDeck(held)
      scheduler.shutdown()
      removeDir(directory)
