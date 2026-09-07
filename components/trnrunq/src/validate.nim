## Resolves the runner executable used by queue workers.

import std/[os, strformat]


proc validateTrnrun*(runnerPath: string): string =
  ## Returns an existing runner path, resolving relative paths beside the queue.
  result =
    if runnerPath.isAbsolute(): runnerPath.normalizedPath()
    else: (getAppDir() / runnerPath).normalizedPath()
  if not fileExists(result):
    raise newException(IOError, fmt"TRNRun not found: '{result}'")

