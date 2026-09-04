## Runs 50 copies of one slow deck through TRNRun Queue and reports each result.
##
## Build both executables first, then run from the `trnrunq` directory:
##
##   cd ../trnrun
##   nimble bin
##   cd ../trnrunq
##   nimble bin
##   nim r tests/manual_queue.nim

import std/[json, monotimes, os, osproc, streams, strutils, tables, terminal, times]


# Manual-run configuration.
const
  DeckFilename = "test_slow_wo_plot_w_tracking.dck"
  CopyCount = 50
  MaxConcurrent = 5
  RemoveStagedCopies = true
  TrnexePath = r"C:\TRNSYS18\Exe\TrnEXE64.exe"
  RunnerArgs = [
    "--trnexePath=" & TrnexePath,
    "--guiVisibility=auto",
    "--waitForGui=true",
    "--waitForLst=true",
    "--waitForTmp=false",
    "--detectTimeout=300000",
    "--watchLog=true",
    "--watchTmp=true",
    "--watchTimeout=0",
    "--stallTimeout=0",
    "--pollMs=100",
    "--clean=false",
    "--killOnTimeout=true",
    "--killOnStall=true",
    "--severity=Notice",
    "--writeEvents=false",
  ]
  TerminalStatuses = ["DONE", "CANCELLED", "ERROR", "TIMEOUT", "STALLED"]

proc formatSeconds(milliseconds: int64): string =
  formatFloat(milliseconds.float / 1_000.0, ffDecimal, 1)

proc stageDecks(sourceDeck, stagingDirectory: string): seq[string] =
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

proc handleOutput(line: string, statuses: var Table[string, string]) =
  echo line
  try:
    let event = parseJson(line)
    if event{"kind"}.getStr() != "STATUS":
      return

    let
      runId = event{"runId"}.getStr()
      status = event{"status"}.getStr()
    if runId.len > 0 and status in TerminalStatuses:
      statuses[runId] = status
  except JsonParsingError:
    discard

proc runQueue(
    executable: string,
    runnerPath: string,
    workingDirectory: string,
    deckFiles: openArray[string],
    statuses: var Table[string, string],
): int =
  var process: Process = nil
  try:
    process = startProcess(
      executable,
      workingDir = workingDirectory,
      args = ["--maxConcurrent=" & $MaxConcurrent],
      options = {poStdErrToStdOut},
    )

    let input = process.inputStream
    for deckFile in deckFiles:
      let request = %*{
        "runId": deckFile.splitFile().name,
        "deckFile": deckFile,
        "runnerPath": runnerPath,
        "runnerArgs": RunnerArgs,
      }
      input.writeLine($request)
      input.flush()
    input.close()

    var line = ""
    while process.peekExitCode() == -1:
      if process.hasData():
        if process.outputStream.readLine(line):
          line.handleOutput(statuses)
      else:
        sleep(10)

    while process.outputStream.readLine(line):
      line.handleOutput(statuses)

    return process.waitForExit()
  except CatchableError as error:
    styledWriteLine(stdout, fgRed, "FAIL - Could not run trnrunq: " & error.msg)
    return -1
  finally:
    if process != nil:
      process.close()

proc main(): int =
  if paramCount() > 0:
    stderr.writeLine(
      "manual_queue does not accept arguments; run: " &
        "nim r tests/manual_queue.nim"
    )
    return 2

  let
    testsDirectory = currentSourcePath().parentDir()
    queueRoot = testsDirectory.parentDir()
    componentsDirectory = queueRoot.parentDir()
    queueExecutable = queueRoot / "build" / "trnrunq.exe"
    runnerExecutable = componentsDirectory / "trnrun" / "build" / "trnrun.exe"
    sourceDeck = testsDirectory / "dck" / DeckFilename
    stagingDirectory = testsDirectory / "runs" /
      ("manual_queue_" & $getCurrentProcessId())

  for executable in [queueExecutable, runnerExecutable, TrnexePath]:
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
      "Running " & $deckFiles.len & " copies with max concurrency " &
        $MaxConcurrent,
    )
    styledWriteLine(stdout, fgWhite, "  Source:  " & sourceDeck)
    styledWriteLine(stdout, fgWhite, "  Staging: " & stagingDirectory)
    echo ""

    var statuses = initTable[string, string]()
    let startedAt = getMonoTime()
    let queueExitCode = runQueue(
      queueExecutable,
      runnerExecutable.absolutePath().normalizedPath(),
      queueRoot,
      deckFiles,
      statuses,
    )

    var failureCount = 0
    echo ""
    for deckFile in deckFiles:
      let runId = deckFile.splitFile().name
      let status = statuses.getOrDefault(runId, "MISSING")
      if status == "DONE":
        styledWriteLine(stdout, fgGreen, "PASS - " & runId & ": " & status)
      else:
        styledWriteLine(stdout, fgRed, "FAIL - " & runId & ": " & status)
        inc failureCount

    if queueExitCode != 0:
      styledWriteLine(
        stdout,
        fgRed,
        "FAIL - trnrunq exited with code " & $queueExitCode,
      )
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
      "FAIL - " & $failureCount & " checks failed in " &
        formatSeconds(durationMs) & "s",
    )
    return 1
  finally:
    if RemoveStagedCopies and dirExists(stagingDirectory):
      removeDir(stagingDirectory)

when isMainModule:
  quit(main())
