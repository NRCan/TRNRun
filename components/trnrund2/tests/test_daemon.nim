import std/[json, os, osproc, streams, strutils, unittest]

import ./fake_trnrun

const TestVersion = "daemon-test-version"

let
  dir = createDeckDir()
  daemonExe = dir / "trnrund2.exe"
  build = execCmdEx(
    "nim c --hints:off -d:NimblePkgVersion=" & TestVersion &
      " --nimcache:" & quoteShell(dir / "nimcache") &
      " --out:" & quoteShell(daemonExe) &
      " " & quoteShell(currentSourcePath.parentDir / "../src/trnrund2.nim")
  )
  trnrunOption = "--trnrun:" & getAppFilename()

proc startDaemon(args: varargs[string]): Process =
  ## Starts the daemon with `args` and piped stdin, stdout and stderr.
  startProcess(daemonExe, workingDir = dir, args = @args, options = {})

proc request(daemon: Process, node: JsonNode): JsonNode =
  ## Sends one request line and reads the one response line it gets.
  daemon.inputStream.writeLine($node)
  daemon.inputStream.flush()
  parseJson(daemon.outputStream.readLine())

proc add(daemon: Process, deckFile: string): int =
  ## Adds `deckFile` and returns its simId.
  daemon.request(%*{"cmd": "add", "deckFile": deckFile})["simId"].getInt()

proc simulation(daemon: Process, simId: int): JsonNode =
  ## The simulation `simId` as `get` returns it.
  daemon.request(%*{"cmd": "get", "simId": simId})["simulation"]

suite "daemon":
  test "builds":
    checkpoint(build.output)
    check build.exitCode == 0

  test "rejects a bad command line with exit code 2":
    let badArgs = [
      @["--bogus"],
      @["extra"],
      @[trnrunOption, "--workers:0"],
      @[trnrunOption, "--workers:x"],
      @["--trnrun:" & dir / "missing.exe"],
    ]
    for args in badArgs:
      let daemon = startDaemon(args)
      check daemon.waitForExit(10_000) == 2
      check daemon.outputStream.readAll() == ""
      check daemon.errorStream.readAll().startsWith("trnrund2: ")
      daemon.close()

  test "prints help and version, even without a TRNRun, and exits 0":
    let missing = "--trnrun:" & dir / "missing.exe"
    for (args, expected) in [
      (@["-h", missing], "trnrund2 - run TRNSYS simulations"),
      (@["--help"], "trnrund2 - run TRNSYS simulations"),
      (@["-v", missing], TestVersion),
      (@["--version"], TestVersion),
    ]:
      let daemon = startDaemon(args)
      check daemon.waitForExit(10_000) == 0
      check daemon.outputStream.readAll().startsWith(expected)
      daemon.close()

  test "answers each request on stdout and keeps simulations moving while idle":
    let
      daemon = startDaemon(trnrunOption, "--workers:1")
      deckFile = createDeck(dir, "wait-a.dck")
    check daemon.request(%*{"cmd": "ready"}) == %*{"ok": true}
    check daemon.request(%*{"cmd": "nope"})["ok"].getBool() == false
    let
      running = daemon.add(deckFile)
      queued = daemon.add(createDeck(dir, "done-a.dck"))
    check daemon.simulation(running)["state"].getStr() == "RUNNING"
    check daemon.simulation(queued)["state"].getStr() == "QUEUED"
    releaseDeck(deckFile)
    sleep(1_000) # No request meanwhile: the daemon must still reap and start simulations.
    let simulation = daemon.simulation(queued)
    check simulation["state"].getStr() == "FINISHED"
    check simulation["succeeded"].getBool()
    daemon.inputStream.close()
    check daemon.waitForExit(10_000) == 0
    check daemon.outputStream.readAll() == ""
    daemon.close()

  test "closing stdin kills running TRNRun and exits 0":
    let
      daemon = startDaemon(trnrunOption)
      deckFile = createDeck(dir, "wait-b.dck")
    check daemon.request(%*{"cmd": "add", "deckFile": deckFile})["ok"].getBool()
    daemon.inputStream.close()
    check daemon.waitForExit(10_000) == 0
    daemon.close()
    releaseDeck(deckFile)
    sleep(500)
    check not fileExists(deckFile.changeFileExt("finished"))

  test "a crashed daemon takes its running TRNRun down with it":
    let
      daemon = startDaemon(trnrunOption)
      deckFile = createDeck(dir, "wait-c.dck")
    check daemon.request(%*{"cmd": "add", "deckFile": deckFile})["ok"].getBool()
    daemon.kill() # Like a crash: the daemon gets no chance to cancel anything.
    discard daemon.waitForExit(10_000)
    daemon.close()
    releaseDeck(deckFile)
    sleep(500)
    check not fileExists(deckFile.changeFileExt("finished"))

removeDir(dir)
