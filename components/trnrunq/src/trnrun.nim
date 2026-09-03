## Runs one trnrun process from spawn through output capture and exit.
##
## Runner output is authoritative. This module validates inputs, owns one child
## process, forwards its complete output lines, and waits for it to finish.

when not defined(windows):
  {.error: "trnrun.nim is Windows-only.".}

import std/[os, osproc, streams, strformat, strutils]


type OutputHandler* = proc(line: string) {.closure, gcsafe.}


proc validateDeck*(deckFile: string): string =
  ## Returns an existing absolute `.dck` or `.trd` path.
  result = deckFile.absolutePath().normalizedPath()
  if not fileExists(result):
    raise newException(IOError, fmt"Deck file not found: '{result}'")
  if result.splitFile().ext.toLowerAscii() notin [".dck", ".trd"]:
    raise newException(
      ValueError,
      fmt"Expected .dck or .trd, got: '{deckFile}'",
    )

proc validateTrnrun*(runnerPath: string): string =
  ## Returns an existing runner path, resolving relative paths beside the queue.
  result =
    if runnerPath.isAbsolute(): runnerPath.normalizedPath()
    else: (getAppDir() / runnerPath).normalizedPath()
  if not fileExists(result):
    raise newException(IOError, fmt"TRNRun not found: '{result}'")


proc runTrnrun*(
    deckFile: string,
    runnerPath: string,
    runId: string,
    runnerArgs: openArray[string],
    onOutput: OutputHandler,
) =
  ## Runs one child synchronously and raises on infrastructure failure.
  let
    deckFile = validateDeck(deckFile)
    executable = validateTrnrun(runnerPath)
    process = startProcess(
      executable,
      args = @[deckFile] & @runnerArgs & @["--runId:" & runId],
      options = {poStdErrToStdOut, poDaemon},
    )

  defer:
    if process.running:
      process.kill()
    process.close()

  var line = ""
  while process.outputStream.readLine(line):
    onOutput(line)

  discard process.waitForExit()


when isMainModule:
  proc printOutput(line: string) {.gcsafe.} =
    echo line

  const
    exampleDeck = currentSourcePath().parentDir().parentDir() /
      "examples" / "dck" / "example_w_plot_w_tracking.dck"
    runnerPath = r"C:\Users\alexl\Documents\Project\Coding\NRCan\TRNRun_V2\TRNRun\components\trnrun\dist\trnrun-v0.5.0-win_amd64\trnrun.exe"

  runTrnrun(
    exampleDeck,
    runnerPath,
    "smoke",
    ["--watchTmp:true"],
    printOutput,
  )
