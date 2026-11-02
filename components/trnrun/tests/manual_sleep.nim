## Checks that `--keepAwake` blocks idle sleep during a long TRNRun simulation.
##
## Reads the system-wide execution state before, during, and after the run, so
## it needs no admin rights (unlike `powercfg /requests`). Leave the PC idle past
## its sleep timeout to see the effect; set `KeepAwake = false` to compare.
##
## Usage:
##
##   nim r tests/manual_sleep.nim

import std/[monotimes, os, osproc, strutils, terminal, times]


# Manual-run configuration. Edit these values to try a different runner setup.
const
  DeckFilename = "extreme_slow_wo_plot_w_tracking.dck"
  TrnexePath = r"C:\TRNSYS18\Exe\TrnEXE64.exe"
  GuiVisibility = "auto"
  KeepAwake = true
  PollMs = 500
  DetectTimeoutMs = 120_000

# Win32 API
proc callNtPowerInformation(
    level: cint, input: pointer, inputLength: uint32,
    output: pointer, outputLength: uint32,
): int32 {.importc: "CallNtPowerInformation", dynlib: "powrprof", stdcall.}
  ## Returns STATUS_SUCCESS (0) on success.

const
  SystemExecutionState = 16.cint
  ES_SYSTEM_REQUIRED = 0x00000001'u32

proc systemRequired(): bool =
  ## True if any thread on the PC is currently blocking idle sleep.
  var state = 0'u32
  if callNtPowerInformation(SystemExecutionState, nil, 0, addr state, uint32(sizeof(state))) != 0:
    raise newException(OSError, "CallNtPowerInformation failed")
  (state and ES_SYSTEM_REQUIRED) != 0

proc formatSeconds(milliseconds: int64): string =
  formatFloat(milliseconds.float / 1_000.0, ffDecimal, 1)

proc main(): int =
  if paramCount() > 0:
    stderr.writeLine(
      "manual_sleep does not accept arguments; run: " &
        "nim r tests/manual_sleep.nim"
    )
    return 2

  let
    testsDirectory = currentSourcePath().parentDir()
    runnerRoot = testsDirectory.parentDir()
    executable = runnerRoot / "build" / "trnrun.exe"
    deckFile = testsDirectory / "../../../decks" / DeckFilename

  if not fileExists(executable):
    styledWriteLine(stdout, fgRed, "ERROR: Executable not found at " & executable)
    return 1
  if not fileExists(deckFile):
    styledWriteLine(stdout, fgRed, "ERROR: Deck file not found at " & deckFile)
    return 1

  let
    arguments = [
      "--deckFile=" & deckFile.absolutePath().normalizedPath(),
      "--trnexePath=" & TrnexePath,
      "--guiVisibility=" & GuiVisibility,
      "--keepAwake=" & $KeepAwake,
    ]
    # Another app (a video, a download) may already block sleep; then the
    # during-run check proves nothing and the after-run check is skipped.
    baseline = systemRequired()

  styledWriteLine(stdout, fgCyan, "Running manual check:")
  styledWriteLine(stdout, fgWhite, "  " & executable & " " & arguments.join(" "))
  styledWriteLine(stdout, fgWhite, "  Sleep blocked before run: " & $baseline)
  echo ""

  let startedAt = getMonoTime()
  var
    process: Process = nil
    exitCode = -1
    blockedDuringRun = false

  try:
    process = startProcess(
      executable,
      workingDir = runnerRoot,
      args = arguments,
      options = {poParentStreams},
    )
    # The request is made just before TrnEXE launches, so poll until it shows.
    while process.running and
        (getMonoTime() - startedAt).inMilliseconds < DetectTimeoutMs:
      if systemRequired():
        blockedDuringRun = true
        break
      sleep(PollMs)
    exitCode = process.waitForExit()
  except CatchableError as error:
    styledWriteLine(stdout, fgRed, "FAIL - Could not run trnrun: " & error.msg)
    return 1
  finally:
    if process != nil:
      process.close()

  let
    durationMs = (getMonoTime() - startedAt).inMilliseconds
    blockedAfterRun = systemRequired()
    summary =
      "Exit code: " & $exitCode & "  Duration: " & formatSeconds(durationMs) &
      "s  Sleep blocked during run: " & $blockedDuringRun &
      "  after run: " & $blockedAfterRun

  echo ""
  var passed = exitCode == 0
  if KeepAwake:
    passed = passed and blockedDuringRun
  elif not baseline:
    passed = passed and not blockedDuringRun
  if not baseline:
    passed = passed and not blockedAfterRun

  if passed:
    styledWriteLine(stdout, fgGreen, "PASS - " & summary)
    return 0

  styledWriteLine(stdout, fgRed, "FAIL - " & summary)
  return 1

when isMainModule:
  quit(main())
