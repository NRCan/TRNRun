import std/[monotimes, options, os, times, unittest]

import ../src/worker/trnrun
import ./fake_trnrun

proc waitForExit(trnrun: var Trnrun): seq[string] =
  ## Reads lines until TRNRun exits, then its last ones; fails after 5 seconds.
  result = @[]
  let deadline = getMonoTime() + initDuration(seconds = 5)
  while trnrun.exitCode().isNone and getMonoTime() < deadline:
    result.add(trnrun.readLines())
    sleep(10)
  check trnrun.exitCode().isSome
  result.add(trnrun.readLastLines())

let dir = createDeckDir()

suite "trnrun":
  test "reads every output line, including a last one without a line break":
    var trnrun = launch(getAppFilename(), createDeck(dir, "done-a.dck"), @[])
    let lines = trnrun.waitForExit()
    trnrun.close()
    check trnrun.exitCode() == some(0)
    check lines.len == 2_000 + 8
    check lines[^1] == """{"kind":"STATUS","status":"DONE","message":"finished"}"""
    check lines[^4] == "not an event"

  test "passes the deck, then trnrunArgs":
    let deckFile = createDeck(dir, "args-b.dck")
    var trnrun = launch(getAppFilename(), deckFile, @["--pollMs:50"])
    discard trnrun.waitForExit()
    trnrun.close()
    check readFile(deckFile.changeFileExt("args")) == deckFile & "\n--pollMs:50"

  test "reports the exit code":
    var trnrun = launch(getAppFilename(), createDeck(dir, "fail-c.dck"), @[])
    discard trnrun.waitForExit()
    check trnrun.exitCode() == some(1)
    trnrun.close()

  test "kill stops a running TRNRun":
    let deckFile = createDeck(dir, "wait-d.dck")
    var trnrun = launch(getAppFilename(), deckFile, @[])
    check trnrun.exitCode().isNone
    trnrun.kill()
    check trnrun.exitCode().isSome
    trnrun.close()
    releaseDeck(deckFile)
    sleep(300)
    check not fileExists(deckFile.changeFileExt("finished"))

  test "launch raises OSError when TRNRun is missing":
    expect OSError:
      discard launch(dir / "missing.exe", createDeck(dir, "done-e.dck"), @[])

removeDir(dir)
