## Runs one trnrun process from spawn through output capture and exit.
##
## Runner output is authoritative. This module validates inputs, owns one child
## process, forwards its complete output lines, and waits for it to finish.

when not defined(windows):
  {.error: "trnrun.nim is Windows-only.".}

import std/[json, os, osproc, streams, strformat, strutils, times]
import ./outputsink


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


proc errorLine(runId, message: string): string =
  ## Returns a runner-compatible terminal event for a request that cannot start.
  $(%*{
    "kind": "STATUS",
    "timestamp": now().format("yyyy-MM-dd'T'HH:mm:ss"),
    "status": "ERROR",
    "message": message,
    "seq": 1,
    "runId": runId,
  })

proc runTrnrun*(
    deckFile: string,
    runnerPath: string,
    runId: string,
    runnerArgs: openArray[string],
    output: var OutputSink,
) =
  ## Runs one child synchronously and reports launch failures through `output`.
  var process: Process = nil
  try:
    let
      deck = validateDeck(deckFile)
      executable = validateTrnrun(runnerPath)
    process = startProcess(
      executable,
      args = @[deck] & @runnerArgs & @["--runId:" & runId],
      options = {poStdErrToStdOut, poDaemon},
    )
  except CatchableError:
    output.emit(errorLine(runId, getCurrentExceptionMsg()))
    return

  try:
    var line = ""
    while process.outputStream.readLine(line):
      output.emit(line)

    discard process.waitForExit()
  finally:
    if process.running:
      process.kill()
    process.close()
