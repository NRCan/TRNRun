## Runs 20 copies of one deck through trnrund and reports each result.
##
## Exercises the client protocol against real TRNSYS: adds every copy, polls
## each simulation with `simulation`, prints state changes, and keeps finished reports
## before releasing their simulations. Build both executables first, then run
## from the `trnrund` directory:
##
##   cd ../trnrun
##   nimble bin
##   cd ../trnrund
##   nimble bin
##   nim r tests/manual_daemon.nim

import std/[json, monotimes, os, osproc, streams, strutils, tables, terminal, times]

# Manual-run configuration.
const
  DeckFilename = "slow_wo_plot_w_tracking.dck"
  CopyCount = 50
  Workers = 25
  PollMs = 500
  TimeoutMs = 3_600_000
  RemoveStagedCopies = true
  TrnexePath = r"C:\TRNSYS18\Exe\TrnEXE64.exe"

let trnrunOptions = %*{
  "trnexePath": TrnexePath,
  "guiVisibility": "auto",
  "waitForGui": true,
  "waitForLst": true,
  "waitForTmp": false,
  "detectTimeout": 300000,
  "watchLog": true,
  "watchTmp": true,
  "watchTimeout": 0,
  "stallTimeout": 0,
  "pollMs": 100,
  "clean": false,
  "killOnTimeout": true,
  "killOnStall": true,
  "severity": "Notice",
  "writeEvents": false,
}

proc formatSeconds(milliseconds: int64): string =
  ## `milliseconds` as seconds, with one decimal.
  return formatFloat(milliseconds.float / 1_000.0, ffDecimal, 1)

proc stageDecks(sourceDeck, stagingDirectory: string): seq[string] =
  ## Copies `sourceDeck` `CopyCount` times, one numbered deck per simulation.
  result = @[]
  let
    sourceName = sourceDeck.splitFile().name
    copyNumberWidth = ($CopyCount).len

  for copyIndex in 1..CopyCount:
    let
      simName = sourceName & "_" & align($copyIndex, copyNumberWidth, '0')
      stagedDeck = stagingDirectory / (simName & ".dck")
    copyFile(sourceDeck, stagedDeck)
    result.add(stagedDeck.absolutePath().normalizedPath())

proc request(daemon: Process, request: JsonNode): JsonNode =
  ## Sends one request and returns its reply.
  ##
  ## Raises `IOError` when the daemon stops answering or rejects the request,
  ## since a manual run cannot continue meaningfully after either.
  daemon.inputStream.writeLine($request)
  daemon.inputStream.flush()
  var line = ""
  if not daemon.outputStream.readLine(line):
    raise newException(IOError, "trnrund closed its output")

  result = parseJson(line)
  if not result["ok"].getBool():
    raise newException(
      IOError, request["cmd"].getStr() & " failed: " & result["error"].getStr()
    )

proc runDaemon(daemon: Process, deckFiles: openArray[string]): Table[string, JsonNode] =
  ## Adds every deck, then polls each unfinished simulation with `simulation` until
  ## it finished, releasing it once reported. Reports are keyed by label, the
  ## deck's name, and include a logCount.
  result = initTable[string, JsonNode]()
  var pending: seq[int] = @[]
  for deckFile in deckFiles:
    # add replies with the simId the daemon assigned; the label names the simulation in reports.
    pending.add(daemon.request(%*{
      "cmd": "add",
      "deckFile": deckFile,
      "trnrunOptions": trnrunOptions,
      "label": deckFile.splitFile().name,
    })["simId"].getInt())

  var states = initTable[string, string]()
  let deadline = getMonoTime() + initDuration(milliseconds = TimeoutMs)

  proc note(name, state: string) =
    ## Prints the state of simulation `name` when it changed since the last poll.
    if states.getOrDefault(name) != state:
      states[name] = state
      styledWriteLine(stdout, fgWhite, "  " & name & ": " & state)

  while result.len < deckFiles.len:
    if not daemon.running:
      raise newException(IOError, "trnrund exited before all simulations finished")
    if getMonoTime() >= deadline:
      raise newException(IOError, "Timed out waiting for simulations")
    var unfinished: seq[int] = @[]
    for simId in pending:
      let simulation = daemon.request(%*{"cmd": "simulation", "simId": simId})["simulation"]
      let name = simulation["label"].getStr()
      note(name, simulation["state"].getStr())
      if simulation["state"].getStr() == "FINISHED":
        result[name] = %*{
          "status": simulation["trnrunStatus"].getStr("NO STATUS"),
          "succeeded": simulation["succeeded"].getBool(),
          "error": simulation["error"].getStr(),
          "logCount": simulation["notices"].getInt() + simulation["warnings"].getInt() + simulation["fatals"].getInt(),
          "warnings": simulation["warnings"].getInt(),
          "fatals": simulation["fatals"].getInt(),
        }
        discard daemon.request(%*{"cmd": "release", "simId": simId})
      else:
        unfinished.add(simId)
    pending = unfinished

    if result.len < deckFiles.len:
      sleep(PollMs)

proc reportRun(name: string, collected: Table[string, JsonNode]): bool =
  ## Prints one simulation's verdict and returns whether it succeeded.
  if name notin collected:
    styledWriteLine(stdout, fgRed, "FAIL - " & name & ": MISSING")
    return false

  let
    simulation = collected[name]
    summary = name & ": " & simulation["status"].getStr() &
      " (" & $simulation["logCount"].getInt() & " logs, " & $simulation["warnings"].getInt() &
      " warnings, " & $simulation["fatals"].getInt() & " fatals)"
  result = simulation["succeeded"].getBool()
  if result:
    styledWriteLine(stdout, fgGreen, "PASS - " & summary)
  else:
    styledWriteLine(stdout, fgRed, "FAIL - " & summary)
    if simulation["error"].getStr().len > 0:
      styledWriteLine(stdout, fgRed, "       " & simulation["error"].getStr())

proc main(): int =
  ## Runs every staged deck through the daemon and returns the exit code.
  if paramCount() > 0:
    stderr.writeLine(
      "manual_daemon does not accept arguments; run: nim r tests/manual_daemon.nim"
    )
    return 2

  let
    testsDirectory = currentSourcePath().parentDir()
    daemonRoot = testsDirectory.parentDir()
    componentsDirectory = daemonRoot.parentDir()
    daemonExecutable = daemonRoot / "build" / "trnrund.exe"
    runnerExecutable = componentsDirectory / "trnrun" / "build" / "trnrun.exe"
    sourceDeck = componentsDirectory.parentDir() / "decks" / DeckFilename
    stagingDirectory = getTempDir() / ("trnrund_manual_daemon_" & $getCurrentProcessId())

  for executable in [daemonExecutable, runnerExecutable, TrnexePath]:
    if not fileExists(executable):
      styledWriteLine(stdout, fgRed, "ERROR: Executable not found at " & executable)
      return 1
  if not fileExists(sourceDeck):
    styledWriteLine(stdout, fgRed, "ERROR: Deck file not found at " & sourceDeck)
    return 1
  if dirExists(stagingDirectory):
    styledWriteLine(stdout, fgRed, "ERROR: Staging directory already exists at " & stagingDirectory)
    return 1

  createDir(stagingDirectory)
  try:
    let deckFiles = stageDecks(sourceDeck, stagingDirectory)
    styledWriteLine(
      stdout,
      fgCyan,
      "Running " & $deckFiles.len & " copies through trnrund with " & $Workers & " workers",
    )
    styledWriteLine(stdout, fgWhite, "  Source:  " & sourceDeck)
    styledWriteLine(stdout, fgWhite, "  Staging: " & stagingDirectory)
    echo ""

    let startedAt = getMonoTime()
    var
      collected = initTable[string, JsonNode]()
      daemonExitCode = -1
    let daemon = startProcess(
      daemonExecutable,
      workingDir = daemonRoot,
      args = ["--trnrun:" & runnerExecutable, "--workers:" & $Workers],
      options = {},
    )
    try:
      collected = daemon.runDaemon(deckFiles)
      daemon.inputStream.close() # The daemon exits once stdin closes.
      daemonExitCode = daemon.waitForExit()
    except CatchableError as error:
      styledWriteLine(stdout, fgRed, "FAIL - Could not run trnrund: " & error.msg)
      if daemon.running:
        daemon.terminate()
      let diagnostics = daemon.errorStream.readAll().strip()
      if diagnostics.len > 0:
        styledWriteLine(stdout, fgRed, "       trnrund stderr: " & diagnostics)
    finally:
      daemon.close()

    var failureCount = 0
    echo ""
    for deckFile in deckFiles:
      if not reportRun(deckFile.splitFile().name, collected):
        inc failureCount

    if daemonExitCode != 0:
      styledWriteLine(stdout, fgRed, "FAIL - trnrund exited with code " & $daemonExitCode)
      inc failureCount

    let durationMs = (getMonoTime() - startedAt).inMilliseconds
    echo ""
    if failureCount == 0:
      styledWriteLine(
        stdout,
        fgGreen,
        "PASS - All simulations completed in " & formatSeconds(durationMs) & "s",
      )
      return 0

    styledWriteLine(
      stdout,
      fgRed,
      "FAIL - " & $failureCount & " checks failed in " & formatSeconds(durationMs) & "s",
    )
    return 1
  finally:
    if RemoveStagedCopies and dirExists(stagingDirectory):
      removeDir(stagingDirectory)

when isMainModule:
  quit(main())
