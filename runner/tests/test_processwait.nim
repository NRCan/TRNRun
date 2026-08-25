import std/[os, osproc, strutils, unittest]

import ../src/processwait


const ChildMode = "--processwait-child"

if paramCount() == 2 and paramStr(1) == ChildMode:
  sleep(parseInt(paramStr(2)))
  quit(QuitSuccess)

proc startTestChild(lifetimeMs: int): Process =
  startProcess(
    getAppFilename(),
    args = [ChildMode, $lifetimeMs],
    options = {},
  )

proc stopAndClose(process: Process) =
  if process.running:
    process.terminate()
    discard process.waitForExit()
  process.close()


suite "non-destructive process waiting":
  test "rejects negative timeout values before accessing the process":
    var
      process: Process = nil
      errorRaised = false
      errorMessage = ""

    try:
      discard process.waitForExitNonDestructive(-1)
    except ValueError as error:
      errorRaised = true
      errorMessage = error.msg

    check errorRaised
    check errorMessage == "timeoutMs must be non-negative"

  test "polls a running process immediately when timeout is zero":
    let process = startTestChild(750)
    defer: process.stopAndClose()

    check not process.waitForExitNonDestructive(0)
    check process.running

  test "does not terminate a process when a positive timeout expires":
    let process = startTestChild(750)
    defer: process.stopAndClose()

    check not process.waitForExitNonDestructive(50)
    check process.running
    check process.waitForExitNonDestructive(2_000)
    check not process.running

  test "returns true when the process exits within the timeout":
    let process = startTestChild(100)
    defer: process.stopAndClose()

    check process.waitForExitNonDestructive(2_000)
    check not process.running

  test "returns true immediately for an already closed process":
    let process = startTestChild(50)
    discard process.waitForExit()
    process.close()

    check process.waitForExitNonDestructive(0)
    check process.waitForExitNonDestructive(100)

  test "supports repeated non-destructive polling":
    let process = startTestChild(500)
    defer: process.stopAndClose()

    for _ in 0 ..< 5:
      check not process.waitForExitNonDestructive(0)
      check process.running
      sleep(20)

    check process.waitForExitNonDestructive(2_000)

  test "bounds oversized timeout values while still observing process exit":
    let process = startTestChild(100)
    defer: process.stopAndClose()

    check process.waitForExitNonDestructive(high(int))
    check not process.running
