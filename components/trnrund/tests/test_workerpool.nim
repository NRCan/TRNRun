import std/[options, os, tempfiles, unittest]
# Included rather than imported so tests can inspect the work channel after shutdown.
include ../src/workerpool

let fakeTrnrun = getAppDir() / "fake_trnrun.exe"
if not fileExists(fakeTrnrun):
  quit("Compile fake_trnrun.exe beside the test executable first", 2)

suite "WorkerPool":
  test "shutdown before start is harmless and submissions require running workers":
    var pool: WorkerPool
    var inbox: Channel[Message]
    inbox.open()
    pool.shutdown()
    pool.shutdown()
    expect ValueError:
      pool.submit(Work(kind: wkRun, runId: "early"))
    expect ValueError:
      pool.submit(Work(kind: wkStop))
    pool.start(fakeTrnrun, 1, addr inbox)
    pool.shutdown()
    pool.shutdown()
    expect ValueError:
      pool.submit(Work(kind: wkRun, runId: "late"))

  test "invalid startup arguments do not consume the one allowed startup":
    var pool: WorkerPool
    var inbox: Channel[Message]
    inbox.open()
    for workers in [0, -1]:
      expect ValueError:
        pool.start(fakeTrnrun, workers, addr inbox)
    expect ValueError:
      pool.start(fakeTrnrun, 1, nil)
    pool.start(fakeTrnrun, 1, addr inbox)
    pool.shutdown()

  test "a pool cannot start twice, even after shutdown":
    var pool: WorkerPool
    var inbox: Channel[Message]
    inbox.open()
    pool.start(fakeTrnrun, 2, addr inbox)
    try:
      expect ValueError:
        pool.start(fakeTrnrun, 1, addr inbox)
    finally:
      pool.shutdown()
    expect ValueError:
      pool.start(fakeTrnrun, 1, addr inbox)
    pool.shutdown()

  test "shutdown drains submitted runs and leaves no stop messages":
    let directory = createTempDir("trnrund-workerpool-", "")
    var pool: WorkerPool
    var inbox: Channel[Message]
    inbox.open()
    try:
      pool.start(fakeTrnrun, 3, addr inbox)
      expect ValueError:
        pool.submit(Work(kind: wkStop))
      for index in 0 ..< 8:
        let runId = "run" & $index
        let deckFile = directory / (runId & ".dck")
        writeFile(deckFile, "fast")
        pool.submit(Work(kind: wkRun, runId: runId, deckFile: deckFile))
      pool.shutdown()
      pool.shutdown()

      var launched, exited: seq[string]
      while true:
        let (available, message) = inbox.tryRecv()
        if not available:
          break
        case message.kind
        of mkLaunched:
          launched.add(message.runId)
        of mkExited:
          exited.add(message.runId)
          check message.exitCode == some(0)
          check message.error.len == 0
        of mkOutput:
          discard
        of mkRequest, mkClosed:
          check false
      check launched.len == 8
      check exited.len == 8
      for index in 0 ..< 8:
        check "run" & $index in launched
        check "run" & $index in exited
      let (available, _) = pool.work.tryRecv()
      check not available
    finally:
      pool.shutdown()
      removeDir(directory)
