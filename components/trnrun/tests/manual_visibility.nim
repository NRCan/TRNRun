## Runs each deck once per `guiVisibility` mode, to check each window mode by eye.
##
## The first set of runs uses a deck without plots, the second one with plots.
## Runs are sequential because they share the deck's sidecar files. `keepOpen`
## and `minimized` leave the TRNSYS window open: close it to start the next run.
##
## Usage:
##
##   nim r tests/manual_visibility.nim

import std/[monotimes, os, osproc, strutils, terminal, times]


# Manual-run configuration. Edit these values to try a different runner setup.
const
  DeckFilenames = ["slow_wo_plot_w_tracking.dck", "slow_w_plot_w_tracking.dck"]
  TrnexePath = r"C:\TRNSYS18\Exe\TrnEXE64.exe"
  GuiVisibilities = ["keepOpen", "autoClose", "minimized", "minimizedAuto", "hidden"]
  WaitForGui = true
  WaitForLst = true
  WaitForTmp = false
  DetectTimeoutMs = 300_000
  ExtraDelayMs = 0
  WatchLog = true
  WatchTmp = true
  WatchTimeoutMs = 7_200_000
  StallTimeoutMs = 300_000
  PollMs = 100
  CleanOnSuccess = true
  KillOnTimeout = true
  KillOnStall = true
  Severity = "Notice"
  WriteEvents = false

proc exitMeaning(exitCode: int): string =
  ## Returns the trnrun outcome name for `exitCode`.
  case exitCode
  of 0: "Done"
  of 1: "Fatal"
  of 2: "User Error"
  of 124: "Timeout"
  of 125: "Stalled"
  of 130: "Cancelled"
  else: "Unknown(" & $exitCode & ")"

proc formatSeconds(milliseconds: int64): string =
  ## Formats `milliseconds` as seconds with one decimal.
  formatFloat(milliseconds.float / 1_000.0, ffDecimal, 1)

proc runMode(executable, runnerRoot, deckFile, guiVisibility: string): bool =
  ## Runs trnrun once with `guiVisibility`, printing PASS or FAIL; true on exit code 0.
  let arguments = [
    "--deckFile=" & deckFile,
    "--trnexePath=" & TrnexePath,
    "--guiVisibility=" & guiVisibility,
    "--waitForGui=" & $WaitForGui,
    "--waitForLst=" & $WaitForLst,
    "--waitForTmp=" & $WaitForTmp,
    "--detectTimeout=" & $DetectTimeoutMs,
    "--extraDelay=" & $ExtraDelayMs,
    "--watchLog=" & $WatchLog,
    "--watchTmp=" & $WatchTmp,
    "--watchTimeout=" & $WatchTimeoutMs,
    "--stallTimeout=" & $StallTimeoutMs,
    "--pollMs=" & $PollMs,
    "--clean=" & $CleanOnSuccess,
    "--killOnTimeout=" & $KillOnTimeout,
    "--killOnStall=" & $KillOnStall,
    "--severity=" & Severity,
    "--writeEvents=" & $WriteEvents,
  ]

  styledWriteLine(
    stdout,
    fgCyan,
    "Running " & deckFile.extractFilename() & " with guiVisibility=" & guiVisibility,
  )
  echo ""

  let startedAt: MonoTime = getMonoTime()
  var
    process: Process = nil
    exitCode: int = -1

  try:
    process = startProcess(
      executable,
      workingDir = runnerRoot,
      args = arguments,
      options = {poParentStreams},
    )
    exitCode = process.waitForExit()
  except CatchableError as error:
    styledWriteLine(stdout, fgRed, "FAIL - Could not run trnrun: " & error.msg)
    return false
  finally:
    if process != nil:
      process.close()

  let summary =
    deckFile.extractFilename() & "  guiVisibility=" & guiVisibility & "  Exit code: " & $exitCode & " (" &
    exitMeaning(exitCode) & ")  Duration: " &
    formatSeconds((getMonoTime() - startedAt).inMilliseconds) & "s"

  echo ""
  if exitCode == 0:
    styledWriteLine(stdout, fgGreen, "PASS - " & summary)
    return true

  styledWriteLine(stdout, fgRed, "FAIL - " & summary)
  return false

proc main(): int =
  ## Runs every deck in every visibility mode in turn; returns 1 if any run failed.
  if paramCount() > 0:
    stderr.writeLine(
      "manual_visibility does not accept arguments; run: " &
        "nim r tests/manual_visibility.nim"
    )
    return 2

  let
    testsDirectory = currentSourcePath().parentDir()
    runnerRoot = testsDirectory.parentDir()
    executable = runnerRoot / "build" / "trnrun.exe"
    runCount = DeckFilenames.len * GuiVisibilities.len

  if not fileExists(executable):
    styledWriteLine(stdout, fgRed, "ERROR: Executable not found at " & executable)
    return 1

  var deckFiles: seq[string] = @[]
  for deckFilename in DeckFilenames:
    let deckFile = (testsDirectory / "../../../decks" / deckFilename).absolutePath().normalizedPath()
    if not fileExists(deckFile):
      styledWriteLine(stdout, fgRed, "ERROR: Deck file not found at " & deckFile)
      return 1
    deckFiles.add(deckFile)

  var failures: int = 0
  for deckFile in deckFiles:
    for guiVisibility in GuiVisibilities:
      if not runMode(executable, runnerRoot, deckFile, guiVisibility):
        inc failures
      echo ""

  if failures == 0:
    styledWriteLine(stdout, fgGreen, "PASS - All " & $runCount & " runs done")
    return 0

  let summary = $failures & " of " & $runCount & " runs failed"
  styledWriteLine(stdout, fgRed, "FAIL - " & summary)
  return 1

when isMainModule:
  quit(main())
