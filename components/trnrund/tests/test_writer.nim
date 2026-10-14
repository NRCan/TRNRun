import std/[atomics, json, locks, monotimes, os, strutils, times, unittest]

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
  withLock outputLock:
    result = written

proc waitForCalls(count: int) =
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while calls.load() < count:
    doAssert getMonoTime() < deadline, "the writer never wrote"
    sleep(1)

proc changed(revision: int): string =
  $(%*{"event": "changed", "revision": revision})

proc runTests() =
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

    test "send returns while a write blocks; replies stay in order before one notification":
      gateOpen.store(false)
      var output = Writer()
      output.start(record, addr inbox, 5)
      output.send(@["a"], 5) # The client already knows revision 5.
      waitForCalls(1)
      output.send(@["b"], 6)
      output.send(@[], 8)
      output.send(@["c"], 7)
      gateOpen.store(true)
      output.stop(5_000)
      check writes() == @[@["a"], @["b", "c", changed(8)]]
      check inbox.peek() == 0
      output.stop(5_000) # A no-op once stopped.

    test "a failed write posts mkClosed once and drops later sends":
      accepting.store(false)
      var output = Writer()
      output.start(record, addr inbox, 0)
      output.send(@["a"], 1)
      check inbox.recv().kind == mkClosed
      output.send(@["b"], 2)
      output.stop(5_000)
      check writes() == @[@["a", changed(1)]]
      check inbox.peek() == 0

    test "stop cancels a write blocked on a client that does not read, after the grace period":
      openUnreadPipe()
      defer: closeUnreadPipe()
      var output = Writer()
      output.start(writeUnread, addr inbox, 0)
      output.send(@[repeat('x', 65_536)], 1)
      let started = getMonoTime()
      output.stop(100)
      let elapsed = getMonoTime() - started
      check elapsed >= initDuration(milliseconds = 100)
      check elapsed < initDuration(seconds = 1)

    test "stop returns at once from an idle writer":
      var output = Writer()
      output.start(record, addr inbox, 0)
      let started = getMonoTime()
      output.stop(5_000)
      check getMonoTime() - started < initDuration(seconds = 1)
      check writes().len == 0

runTests()
