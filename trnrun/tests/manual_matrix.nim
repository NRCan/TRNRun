## Runs every TRNRun deck/setting integration combination.
##
## Usage:
##
##   nim r tests/manual_matrix.nim

import std/[monotimes, os, osproc, strutils, terminal, times]


type
  ParameterValues = object
    name: string
    values: seq[string]

  RunResult = object
    exitCode: int
    errorMessage: string

proc parameterMatrix(): seq[ParameterValues] =
  @[
    ParameterValues(name: "guiVisibility", values: @["hidden"]),
    ParameterValues(name: "waitForGui", values: @["true"]),
    ParameterValues(name: "waitForLst", values: @["true"]),
    ParameterValues(name: "waitForTmp", values: @["true", "false"]),
    ParameterValues(name: "detectTimeout", values: @["0"]),
    ParameterValues(name: "extraDelay", values: @["0"]),
    ParameterValues(name: "watchLog", values: @["true", "false"]),
    ParameterValues(name: "watchTmp", values: @["true", "false"]),
    ParameterValues(name: "watchTimeout", values: @["0"]),
    ParameterValues(name: "stallTimeout", values: @["0"]),
    ParameterValues(name: "pollMs", values: @["10"]),
    ParameterValues(name: "clean", values: @["false"]),
    ParameterValues(name: "killOnTimeout", values: @["true", "false"]),
    ParameterValues(name: "killOnStall", values: @["true", "false"]),
    ParameterValues(name: "severity", values: @["Notice"]),
    ParameterValues(name: "writeEvents", values: @["false"]),
  ]

proc countCombinations(matrix: openArray[ParameterValues]): int =
  result = 1
  for parameter in matrix:
    result *= parameter.values.len

proc combinationAt(
    index: int,
    matrix: openArray[ParameterValues],
): seq[string] =
  result = @[]
  var remainingIndex = index

  for parameter in matrix:
    let valueCount = parameter.values.len
    result.add(parameter.values[remainingIndex mod valueCount])
    remainingIndex = remainingIndex div valueCount

proc runnerArguments(
    deckFile: string,
    matrix: openArray[ParameterValues],
    values: openArray[string],
): seq[string] =
  result = @["--deckFile=" & deckFile]
  for index, parameter in matrix:
    result.add("--" & parameter.name & "=" & values[index])

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

proc runRunner(
    executable: string,
    arguments: openArray[string],
    workingDirectory: string,
): RunResult =
  result = RunResult(exitCode: -1, errorMessage: "")
  var process: Process = nil

  try:
    process = startProcess(
      executable,
      workingDir = workingDirectory,
      args = arguments,
      options = {poParentStreams},
    )
    result.exitCode = process.waitForExit()
  except CatchableError as error:
    result.errorMessage = error.msg
  finally:
    if process != nil:
      process.close()

proc requiredDecks(testsDirectory: string): seq[string] =
  result = @[]
  for filename in [
    "test_fast_wo_plot_wo_tracking.dck",
    "test_fast_wo_plot_w_tracking.dck",
    "test_fast_w_plot_wo_tracking.dck",
    "test_fast_w_plot_w_tracking.dck",
  ]:
    let path = testsDirectory / "dck" / filename
    if not fileExists(path):
      raise newException(IOError, "Required deck file not found: " & path)
    result.add(path.absolutePath().normalizedPath())

proc main(): int =
  if paramCount() > 0:
    stderr.writeLine(
      "manual_matrix does not accept arguments; run: " &
        "nim r tests/manual_matrix.nim"
    )
    return 2

  let
    testsDirectory = currentSourcePath().parentDir()
    runnerRoot = testsDirectory.parentDir()
    executable = runnerRoot / "build" / "trnrun.exe"
    matrix = parameterMatrix()
    combinationCount = matrix.countCombinations()
    deckFiles = requiredDecks(testsDirectory)
    totalRuns = combinationCount * deckFiles.len

  if not fileExists(executable):
    styledWriteLine(stdout, fgRed, "ERROR: Executable not found at " & executable)
    return 1

  styledWriteLine(
    stdout,
    fgCyan,
    "Parameter combinations: " & $combinationCount,
  )
  styledWriteLine(stdout, fgCyan, "Deck files:            " & $deckFiles.len)
  styledWriteLine(stdout, fgCyan, "Total runs:            " & $totalRuns)

  var
    runOrdinal = 0
    failureCount = 0
  let batchStartedAt = getMonoTime()

  for deckFile in deckFiles:
    let deckName = deckFile.splitFile().name

    for combinationIndex in 0 ..< combinationCount:
      inc runOrdinal
      let
        values = combinationAt(combinationIndex, matrix)
        arguments = runnerArguments(deckFile, matrix, values)
        percentComplete = 100.0 * runOrdinal.float / totalRuns.float

      echo ""
      styledWriteLine(
        stdout,
        fgCyan,
        "==================================================================",
      )
      styledWriteLine(
        stdout,
        fgCyan,
        "[" & $runOrdinal & "/" & $totalRuns & " (" &
          formatFloat(percentComplete, ffDecimal, 2) & "%)] dck=" &
          deckName & " combo=" & $combinationIndex,
      )
      styledWriteLine(stdout, fgWhite, arguments.join(" "))
      styledWriteLine(
        stdout,
        fgCyan,
        "==================================================================",
      )

      let
        startedAt = getMonoTime()
        runResult = runRunner(executable, arguments, runnerRoot)
        durationMs = (getMonoTime() - startedAt).inMilliseconds
        summary =
          "Exit code: " & $runResult.exitCode & " (" &
          exitMeaning(runResult.exitCode) & ")  Duration: " &
          formatSeconds(durationMs) & "s"

      if runResult.errorMessage.len > 0:
        styledWriteLine(
          stdout,
          fgRed,
          "Failed to start runner: " & runResult.errorMessage,
        )

      if runResult.exitCode == 0:
        styledWriteLine(stdout, fgGreen, "PASS - " & summary)
      else:
        styledWriteLine(stdout, fgRed, "FAIL - " & summary)
        inc failureCount

  let elapsedMs = (getMonoTime() - batchStartedAt).inMilliseconds
  echo ""
  styledWriteLine(
    stdout,
    fgYellow,
    "==================================================================",
  )

  if failureCount == 0:
    styledWriteLine(
      stdout,
      fgGreen,
      "PASS - All " & $totalRuns & " runs passed in " &
        formatSeconds(elapsedMs) & "s",
    )
  else:
    styledWriteLine(
      stdout,
      fgRed,
      "FAIL - " & $failureCount & " of " & $totalRuns &
        " runs failed in " & formatSeconds(elapsedMs) & "s",
    )

  styledWriteLine(
    stdout,
    fgYellow,
    "==================================================================",
  )

  if failureCount == 0: 0 else: 1

when isMainModule:
  let exitCode =
    try:
      main()
    except CatchableError as error:
      stderr.writeLine("Error: ", error.msg)
      2
  quit(exitCode)
