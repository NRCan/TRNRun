import std/[atomics, locks, monotimes, os, strutils, times, unittest]

import ../src/[messages, writer]
import ./fake_client

var
  outputLock: Lock
  written: seq[seq[string]] ## The lines of each write, guarded by `outputLock`.
  calls: Atomic[int] ## Writes begun.
  gateOpen: Atomic[bool] ## Writes wait until it is set.
  accepting: Atomic[bool] ## Whether writes succeed.

proc record(lines: seq[string]): bool {.nimcall, gcsafe, raises: [].} =
  ## Records one write once the gate opens; fails unless accepting.
  calls.atomicInc()
  while not gateOpen.load():
    sleep(1)
  {.cast(gcsafe).}:
    withLock outputLock:
      written.add(lines)
  accepting.load()

proc writes(): seq[seq[string]] =
  ## The lines of every write so far.
  withLock outputLock:
    result = written

proc waitForCalls(count: int) =
  ## Waits until `count` writes began; fails after 5 seconds.
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while calls.load() < count:
    doAssert getMonoTime() < deadline, "the writer never wrote"
    sleep(1)

proc runTests() =
  ## Runs the writer tests.
  initLock(outputLock)

  suite "writer":
    var inbox = default(Channel[Message])
    inbox.open() # Never closed, as in the daemon.

    setup:
      written = @[]
      calls.store(0)
      gateOpen.store(true)
      accepting.store(true)
      while inbox.tryRecv().dataAvailable:
        discard

    test "send returns while a write blocks; replies stay in order, and nothing else is written":
      gateOpen.store(false)
      var output = Writer()
      output.start(record, addr inbox)
      output.send(@["a"])
      waitForCalls(1)
      output.send(@["b"])
      output.send(@[])
      output.send(@["c", "d"])
      gateOpen.store(true)
      output.stop(5_000)
      check writes() == @[@["a"], @["b", "c", "d"]]
      check inbox.peek() == 0
      output.stop(5_000) # A no-op once stopped.

    test "a failed write posts mkClosed once and drops later sends":
      accepting.store(false)
      var output = Writer()
      output.start(record, addr inbox)
      output.send(@["a"])
      check inbox.recv().kind == mkClosed
      output.send(@["b"])
      output.stop(5_000)
      check writes() == @[@["a"]]
      check inbox.peek() == 0

    test "stop cancels a write blocked on a client that does not read, after the grace period":
      openUnreadPipe()
      defer: closeUnreadPipe()
      var output = Writer()
      output.start(writeUnread, addr inbox)
      output.send(@[repeat('x', 65_536)])
      let started = getMonoTime()
      output.stop(100)
      let elapsed = getMonoTime() - started
      check elapsed >= initDuration(milliseconds = 100)
      check elapsed < initDuration(seconds = 1)

    test "stop returns at once from an idle writer":
      var output = Writer()
      output.start(record, addr inbox)
      let started = getMonoTime()
      output.stop(5_000)
      check getMonoTime() - started < initDuration(seconds = 1)
      check writes().len == 0

runTests()
