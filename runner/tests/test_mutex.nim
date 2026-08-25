import std/[atomics, os, unittest]

include ../src/mutex


type WaiterArgs = object
  timeoutMs: int32
  releaseAfterAcquire: bool

const WorkerNotFinished = -1'i32

var
  workerStarted: Atomic[bool]
  workerWaitResult: Atomic[int32]

proc resetWorkerState() =
  workerStarted.store(false)
  workerWaitResult.store(WorkerNotFinished)

proc waitForLaunchMutex(args: WaiterArgs) {.thread.} =
  let mutex = getLaunchMutex()
  workerStarted.store(true)

  let waitResult = waitForSingleObject(mutex, args.timeoutMs)
  workerWaitResult.store(waitResult)

  if args.releaseAfterAcquire and
      (waitResult == WAIT_OBJECT_0 or waitResult == WAIT_ABANDONED):
    discard releaseMutex(mutex)

proc acquireAndAbandon(_: int) {.thread.} =
  let mutex = getLaunchMutex()
  workerStarted.store(true)
  workerWaitResult.store(waitForSingleObject(mutex, 1_000))
  # Exiting this thread without releasing an acquired mutex abandons it.

proc waitUntilWorkerStarts(): bool =
  for _ in 0 ..< 200:
    if workerStarted.load():
      return true
    sleep(10)
  false


{.push warning[ProveInit]: off, warning[Uninit]: off.}

suite "TRNSYS launch mutex":
  test "creates and caches one named mutex handle":
    check launchMutexHandle == 0

    let firstHandle = getLaunchMutex()
    let secondHandle = getLaunchMutex()

    check firstHandle != 0
    check secondHandle == firstHandle
    check launchMutexHandle == firstHandle

  test "runs the protected body":
    var bodyRan = false

    withLaunchLock:
      bodyRan = true

    check bodyRan

  test "allows nested acquisition on the owning thread":
    var executionCount = 0

    withLaunchLock:
      inc executionCount
      withLaunchLock:
        inc executionCount

    check executionCount == 2

  test "releases the mutex when the protected body raises":
    var
      bodyRan = false
      errorRaised = false

    try:
      withLaunchLock:
        bodyRan = true
        raise newException(ValueError, "expected test failure")
    except ValueError:
      errorRaised = true

    check bodyRan
    check errorRaised

    resetWorkerState()
    var worker = default(Thread[WaiterArgs])
    createThread(
      worker,
      waitForLaunchMutex,
      WaiterArgs(timeoutMs: 1_000, releaseAfterAcquire: true),
    )
    joinThread(worker)

    check workerStarted.load()
    check workerWaitResult.load() == WAIT_OBJECT_0

  test "blocks another thread until the owner releases":
    let mutex = acquireLaunchLock()
    resetWorkerState()
    var worker = default(Thread[WaiterArgs])
    var workerWasBlocked = false

    try:
      createThread(
        worker,
        waitForLaunchMutex,
        WaiterArgs(timeoutMs: 2_000, releaseAfterAcquire: true),
      )
      let workerDidStart = waitUntilWorkerStarts()
      sleep(100)
      workerWasBlocked =
        workerDidStart and workerWaitResult.load() == WorkerNotFinished
    finally:
      releaseLaunchLock(mutex)

    joinThread(worker)

    check workerWasBlocked
    check workerWaitResult.load() == WAIT_OBJECT_0

  test "recovers ownership when a previous thread abandons the mutex":
    resetWorkerState()
    var worker = default(Thread[int])
    createThread(worker, acquireAndAbandon, 0)
    joinThread(worker)

    check workerStarted.load()
    check workerWaitResult.load() == WAIT_OBJECT_0

    let mutex = acquireLaunchLock()
    check mutex == launchMutexHandle
    releaseLaunchLock(mutex)

{.pop.}
