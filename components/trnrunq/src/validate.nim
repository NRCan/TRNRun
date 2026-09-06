## Validates runner inputs.
##
## Deck paths are normalized and restricted to supported file types. Runner
## paths are normalized relative to the queue executable when needed.

import std/[os, strformat, strutils]


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

