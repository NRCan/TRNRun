## Creates placeholder deck files for tests.
##
## The content is never read: validation only checks the extension, and
## `fake_trnrun` picks its behaviour from the deck name.

import std/os

proc createDeck*(directory, name: string): string =
  ## Writes a placeholder deck named `name` in `directory` and returns its path.
  result = directory / name
  writeFile(result, "fake TRNSYS deck")
