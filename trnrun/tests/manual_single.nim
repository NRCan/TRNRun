## Runs one representative TRNRun simulation as a quick manual check.
##
## Usage:
##
##   nim r tests/manual_single.nim

import std/[monotimes, os, osproc, strutils, terminal, times]


# Manual-run configuration. Edit these values to try a different runner setup.
const
  DeckFilename = "test_slow_wo_plot_w_tracking.dck"
  TrnexePath = r"C:\TRNSYS18\Exe\TrnEXE64.exe"
  GuiVisibility = "auto"
  WaitForGui = true
  WaitForLst = true
  WaitForTmp = false
  DetectTimeoutMs = 0
  ExtraDelayMs = 0
  WatchLog = true
  WatchTmp = true
  WatchTimeoutMs = 0
  StallTimeoutMs = 0
  PollMs = 100
  CleanOnSuccess = false
  KillOnTimeout = false
  KillOnStall = false
  Severity = "Notice"
  WriteEvents = false

proc exitMeaning(exitCode: int): string =
  case exitCode
  of 0: "Done"
  of 1: "Fatal"
  of 2: "User Error"
  of 124: "Timeout"
  of 125: "Stalled"
  of 130: "Cancelled"
  else: "Unknown(" & $exitCode & ")"

proc formatSeconds(milliseconds: int64): string =
  formatFloat(milliseconds.float / 1_000.0, ffDecimal, 1)

proc main(): int =
  if paramCount() > 0:
    stderr.writeLine(
      "manual_single does not accept arguments; run: " &
        "nim r tests/manual_single.nim"
    )
    return 2

  let
    testsDirectory = currentSourcePath().parentDir()
    runnerRoot = testsDirectory.parentDir()
    executable = runnerRoot / "build" / "trnrun.exe"
    deckFile = testsDirectory / "dck" / DeckFilename

  if not fileExists(executable):
    styledWriteLine(stdout, fgRed, "ERROR: Executable not found at " & executable)
    return 1
  if not fileExists(deckFile):
    styledWriteLine(stdout, fgRed, "ERROR: Deck file not found at " & deckFile)
    return 1

  let arguments = [
    "--deckFile=" & deckFile.absolutePath().normalizedPath(),
    "--trnexePath=" & TrnexePath,
    "--guiVisibility=" & GuiVisibility,
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

  styledWriteLine(stdout, fgCyan, "Running manual check:")
  styledWriteLine(stdout, fgWhite, "  " & executable & " " & arguments.join(" "))
  echo ""

  let startedAt = getMonoTime()
  var process: Process = nil
  var exitCode = -1

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
    return 1
  finally:
    if process != nil:
      process.close()

  let
    durationMs = (getMonoTime() - startedAt).inMilliseconds
    summary =
      "Exit code: " & $exitCode & " (" & exitMeaning(exitCode) &
      ")  Duration: " & formatSeconds(durationMs) & "s"

  echo ""
  if exitCode == 0:
    styledWriteLine(stdout, fgGreen, "PASS - " & summary)
    return 0

  styledWriteLine(stdout, fgRed, "FAIL - " & summary)
  return 1

when isMainModule:
  quit(main())
