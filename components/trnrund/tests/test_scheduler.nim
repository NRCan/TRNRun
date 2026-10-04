import std/[options, os, tempfiles, times, unittest]
import ../src/events
import ../src/scheduler

let fakeTrnrun = getAppDir() / "fake_trnrun.exe"
if not fileExists(fakeTrnrun):
  quit("Compile fake_trnrun.exe beside the test executable first", 2)

proc deck(directory, name: string, mode: string = "fast"): string =
  result = directory / (name & ".dck")
  writeFile(result, mode)

proc releaseDeck(path: string) =
  writeFile(path & ".release", "")

template pollUntil(scheduler: Scheduler, condition: untyped, failure: string) =
  ## Applies scheduler messages until `condition` holds, failing after 4 s.
  let deadline = epochTime() + 4
  while true:
    discard scheduler.poll()
    if condition:
      break
    if epochTime() > deadline:
      raise newException(AssertionDefect, failure)
    sleep(5)

proc awaitReady(scheduler: Scheduler, path: string) =
  scheduler.pollUntil(fileExists(path & ".ready"), "TRNRun did not become ready: " & path)

proc awaitStatus(scheduler: Scheduler, runId: string, status: SimStatus) =
  scheduler.pollUntil(
    scheduler.snapshot(runId).status.get(StatusEvent()).status == status,
    "TRNRun did not report expected status",
  )

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
    check scheduler.poll() == 0
    scheduler.shutdown()
    scheduler.shutdown()
    check scheduler.poll() == 0

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
          discard scheduler.snapshot(runId)
      expect KeyError:
        scheduler.wait("unknown")

      scheduler.add("valid", path)
      expect ValueError:
        scheduler.add("valid", path)
      scheduler.wait()
      check scheduler.snapshot("valid").succeeded()
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
      check scheduler.snapshot("first").state == ssAccepted
      check scheduler.snapshot("second").state == ssQueued
      check scheduler.snapshot("third").state == ssQueued

      scheduler.awaitReady(first)
      scheduler.awaitStatus("first", statusDone)
      check scheduler.snapshot("first").state == ssRunning
      check not scheduler.snapshot("first").succeeded()
      check scheduler.snapshot("second").state == ssQueued
      check not fileExists(second & ".ready")

      releaseDeck(first)
      scheduler.wait("first")
      check scheduler.snapshot("first").succeeded()
      check scheduler.snapshot("second").state == ssAccepted
      check scheduler.snapshot("third").state == ssQueued
      scheduler.awaitReady(second)
      releaseDeck(second)
      scheduler.wait()
      for runId in ["first", "second", "third"]:
        check scheduler.snapshot(runId).succeeded()
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
      check scheduler.snapshot("third").state == ssQueued
      check not fileExists(third & ".ready")
      releaseDeck(first)
      scheduler.wait("third")
      check scheduler.snapshot("third").succeeded()
      check scheduler.snapshot("second").state != ssFinished
      releaseDeck(second)
      scheduler.wait()
    finally:
      releaseDeck(first)
      releaseDeck(second)
      scheduler.shutdown()
      removeDir(directory)

  test "launch failures finish and free capacity for the next queued run":
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
      scheduler.snapshot("removed").checkLaunchFailed()
      check scheduler.snapshot("last").succeeded()
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
        scheduler.snapshot(runId).checkLaunchFailed()
    finally:
      scheduler.shutdown()
      removeDir(directory)

  test "snapshots and logs are copies, and snapshots leave logs out":
    let directory = createTempDir("trnrund-snapshot-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let path = deck(directory, "first")
    try:
      var args = @["--test"]
      scheduler.add("first", path, args)
      args[0] = "caller change"
      scheduler.wait()
      var snapshot = scheduler.snapshot("first")
      check snapshot.logs.len == 0
      check snapshot.notices == 1
      snapshot.trnrunArgs[0][0] = 'X'
      snapshot.status.get().message = "changed"
      var entries = scheduler.logs("first")
      entries[0].message = some("changed")
      entries.add(LogEvent(severity: Fatal))

      let original = scheduler.snapshot("first")
      check original.trnrunArgs == @["--test"]
      check original.status.get().message == "Completed"
      check scheduler.logs("first").len == 1
      check scheduler.logs("first")[0].message == some("Started")
      expect KeyError:
        discard scheduler.logs("unknown")
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
      scheduler.remove("held")
      expect KeyError:
        discard scheduler.snapshot("held")
      check scheduler.snapshot("fast").succeeded()

      # A removed runId can be submitted again.
      scheduler.add("held", fast)
      scheduler.wait("held")
      check scheduler.snapshot("held").succeeded()
    finally:
      releaseDeck(held)
      scheduler.shutdown()
      removeDir(directory)

  test "poll is bounded and shutdown cancels queued work but finishes running work":
    let directory = createTempDir("trnrund-shutdown-", "")
    let scheduler = newScheduler(fakeTrnrun, 1)
    let held = deck(directory, "held", "hold")
    try:
      scheduler.add("held", held)
      scheduler.add("queued", deck(directory, "queued"))
      # Without polling, the launch and output messages pile up in the inbox.
      let deadline = epochTime() + 4
      while not fileExists(held & ".ready") and epochTime() < deadline:
        sleep(5)
      sleep(100)
      check scheduler.poll(1) == 1
      check scheduler.poll() > 0
      # The held run's exit is not processed yet, so "queued" is still queued.
      releaseDeck(held)
      scheduler.shutdown()
      check scheduler.snapshot("held").succeeded()
      let queued = scheduler.snapshot("queued")
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
