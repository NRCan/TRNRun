## Runs 20 copies of one slow deck through the TRNRun daemon and reports each result.
##
## Exercises the client protocol and database against real TRNSYS: adds every
## copy, reads run columns through a query-only connection, prints state
## changes, and keeps finished reports. Build both executables first, then run
## from the `trnrund` directory:
##
##   cd ../trnrun
##   nimble bin
##   cd ../trnrund
##   nimble bin
##   nim r tests/manual_daemon.nim

import std/[json, monotimes, os, osproc, streams, strutils, tables, terminal, times]
import db_connector/db_sqlite


# Manual-run configuration.
const
  DeckFilename = "test_slow_wo_plot_w_tracking.dck"
  CopyCount = 20
  MaxConcurrent = 5
  PollMs = 500
  TimeoutMs = 3_600_000
  RemoveStagedCopies = true
  TrnexePath = r"C:\TRNSYS18\Exe\TrnEXE64.exe"
  TrnrunArgs = [
    "--trnexePath:" & TrnexePath,
    "--guiVisibility:auto",
    "--waitForGui:true",
    "--waitForLst:true",
    "--waitForTmp:false",
    "--detectTimeout:300000",
    "--watchLog:true",
    "--watchTmp:true",
    "--watchTimeout:0",
    "--stallTimeout:0",
    "--pollMs:100",
    "--clean:false",
    "--killOnTimeout:true",
    "--killOnStall:true",
    "--severity:Notice",
    "--writeEvents:false",
  ]


proc formatSeconds(milliseconds: int64): string =
  formatFloat(milliseconds.float / 1_000.0, ffDecimal, 1)

proc stageDecks(sourceDeck, stagingDirectory: string): seq[string] =
  ## Copies `sourceDeck` `CopyCount` times, one numbered deck per run.
  result = @[]
  let
    sourceName = sourceDeck.splitFile().name
    copyNumberWidth = ($CopyCount).len

  for copyIndex in 1 .. CopyCount:
    let
      runName = sourceName & "_" & align($copyIndex, copyNumberWidth, '0')
      stagedDeck = stagingDirectory / (runName & ".dck")
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
  ## Reads the runs changed since the last poll from the database, without
  ## sending commands while workers run. Finished reports include a logCount.
  result = initTable[string, JsonNode]()
  let ready = daemon.request(%*{"cmd": "ready"})
  let db = db_sqlite.open(ready["databasePath"].getStr(), "", "", "")
  defer: db.close()
  db.exec(sql"PRAGMA query_only = ON")
  for deckFile in deckFiles:
    discard daemon.request(%*{
      "cmd": "add",
      "runId": deckFile.splitFile().name,
      "deckFile": deckFile,
      "trnrunArgs": TrnrunArgs,
    })

  var
    states = initTable[string, string]()
    revision = 0'i64
  let deadline = getMonoTime() + initDuration(milliseconds = TimeoutMs)

  proc note(runId, state: string) =
    if states.getOrDefault(runId) != state:
      states[runId] = state
      styledWriteLine(stdout, fgWhite, "  " & runId & ": " & state)

  while result.len < deckFiles.len:
    if not daemon.running:
      raise newException(IOError, "trnrund exited before all runs finished")
    if getMonoTime() >= deadline:
      raise newException(IOError, "Timed out waiting for runs in the database")
    for row in db.getAllRows(sql"""SELECT run_id, revision, state, trnrun_status, succeeded, error,
      notices + warnings + fatals, warnings, fatals
      FROM runs WHERE revision > ? ORDER BY revision""", revision):
      let runId = row[0]
      revision = parseBiggestInt(row[1])
      note(runId, row[2])
      if row[2] == "FINISHED":
        result[runId] = %*{
          "status": (if row[3].len > 0: row[3] else: "NO STATUS"),
          "succeeded": row[4] == "1",
          "error": row[5],
          "logCount": parseInt(row[6]),
          "warnings": parseInt(row[7]),
          "fatals": parseInt(row[8]),
        }

    if result.len < deckFiles.len:
      sleep(PollMs)

proc reportRun(runId: string, collected: Table[string, JsonNode]): bool =
  ## Prints one run's verdict and returns whether it succeeded.
  if runId notin collected:
    styledWriteLine(stdout, fgRed, "FAIL - " & runId & ": MISSING")
    return false

  let
    simulation = collected[runId]
    summary = runId & ": " & simulation["status"].getStr() &
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
    sourceDeck = testsDirectory / "dck" / DeckFilename
    stagingDirectory = testsDirectory / "runs" /
      ("manual_daemon_" & $getCurrentProcessId())

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
      "Running " & $deckFiles.len & " copies through trnrund with max concurrency " &
        $MaxConcurrent,
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
      args = ["--trnrun:" & runnerExecutable, "--maxConcurrent:" & $MaxConcurrent,
              "--database:" & (stagingDirectory / "runs.sqlite3")],
      options = {},
    )
    try:
      collected = daemon.runDaemon(deckFiles)
      discard daemon.request(%*{"cmd": "shutdown"})
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
        "PASS - All runs completed in " & formatSeconds(durationMs) & "s",
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
