## Validates deck and TRNRun paths.
##
## Relative deck and TRNRun paths are both resolved from the daemon working
## directory, which a wrapper inherits by default. Decks are restricted to
## supported file types. Failures raise `ValueError` so the daemon can reject the
## request instead of treating them as I/O faults.

import std/[os, strformat, strutils]

proc validateDeck*(deckFile: string): string =
  ## Returns an existing absolute `.dck` or `.trd` path.
  result = deckFile.absolutePath().normalizedPath()
  if not fileExists(result):
    raise newException(ValueError, fmt"Deck file not found: '{result}'")
  if result.splitFile().ext.toLowerAscii() notin [".dck", ".trd"]:
    raise newException(ValueError, fmt"Expected .dck or .trd, got: '{deckFile}'")

proc validateTrnrun*(trnrunPath: string): string =
  ## Returns an existing absolute TRNRun path.
  result = trnrunPath.absolutePath().normalizedPath()
  if not fileExists(result):
    raise newException(ValueError, fmt"TRNRun not found: '{result}'")
