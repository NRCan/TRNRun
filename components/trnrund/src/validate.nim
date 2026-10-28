## Validates deck and TRNRun paths, and the shape of TRNRun options.
##
## Relative deck and TRNRun paths are both resolved from the daemon working
## directory, which a wrapper inherits by default. Decks are restricted to
## supported file types. TRNRun options are not checked against TRNRun's own
## vocabulary: TRNRun rejects a bad one when the simulation starts. Failures
## raise `InputError` so the daemon can reject the input instead of treating it
## as a daemon fault.

import std/[json, os, strformat, strutils]

type InputError* = object of ValueError
  ## Input from the command line or a client was rejected; never a daemon fault.

const ReservedOptions = ["deckFile", "help", "h", "version", "v"]
  ## TRNRun options that pick another deck than the daemon passes, or stop TRNRun from running.

proc validateFile*(path, description: string): string =
  ## Returns `path` absolute and normalized; `InputError`, naming `description`, if no file is there.
  result = path.absolutePath().normalizedPath()
  if not fileExists(result):
    raise newException(InputError, fmt"{description} not found: '{result}'")

proc validateDeck*(deckFile: string): string =
  ## Returns `deckFile` absolute and normalized; `InputError` unless it is a `.dck` or `.trd` file.
  result = validateFile(deckFile, "Deck file")
  if result.splitFile().ext.toLowerAscii() notin [".dck", ".trd"]:
    raise newException(InputError, fmt"Expected .dck or .trd, got: '{deckFile}'")

proc validateTrnrunOptions*(trnrunOptions: JsonNode) =
  ## Checks the `trnrunOptions` object before TRNRun gets it as `--key:value` arguments.
  ##
  ## Each name must be letters and digits only, so TRNRun reads back the same
  ## name, and not one of `ReservedOptions`, since the daemon passes the deck
  ## itself and needs TRNRun to run. Each value must be a string, boolean or
  ## number. Raises `InputError` naming the first bad option.
  for key, value in trnrunOptions:
    if key.len == 0 or not key.allCharsInSet(Letters + Digits):
      raise newException(InputError, fmt"Invalid option name in trnrunOptions: '{key}'")
    if key in ReservedOptions:
      raise newException(InputError, fmt"Option not allowed in trnrunOptions: '{key}'")
    if value.kind notin {JString, JBool, JInt, JFloat}:
      raise newException(InputError, fmt"'trnrunOptions.{key}' must be a string, boolean or number")
