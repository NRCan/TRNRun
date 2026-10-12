## Validates deck and TRNRun paths, and TRNRun arguments.
##
## Relative deck and TRNRun paths are both resolved from the daemon working
## directory, which a wrapper inherits by default. Decks are restricted to
## supported file types. TRNRun arguments are parsed with TRNRun's own option
## vocabulary, so a bad one is rejected when the run is added rather than when
## it starts. Failures raise `ValueError` so the daemon can reject the request
## instead of treating them as I/O faults.

import std/[os, parseopt, strformat, strutils]
import ../../trnrun/src/cli as trnrunCli

const DaemonOptions = ["deckFile", "runId", "help", "h", "version", "v"]
  ## TRNRun options the daemon sets itself, or that stop TRNRun from running.

proc validateFile*(path, label: string): string =
  ## Returns `path` absolute and normalized; `ValueError` if no file is there.
  result = path.absolutePath().normalizedPath()
  if not fileExists(result):
    raise newException(ValueError, fmt"{label} not found: '{result}'")

proc validateDeck*(deckFile: string): string =
  ## Returns an existing absolute `.dck` or `.trd` path.
  result = validateFile(deckFile, "Deck file")
  if result.splitFile().ext.toLowerAscii() notin [".dck", ".trd"]:
    raise newException(ValueError, fmt"Expected .dck or .trd, got: '{deckFile}'")

proc validateTrnrunArgs*(trnrunArgs: openArray[string]) =
  ## Raises `ValueError` unless TRNRun accepts every option in `trnrunArgs`.
  ##
  ## Rejects positional arguments and `DaemonOptions` too: the daemon passes
  ## the deck and runId itself.
  if trnrunArgs.len == 0:
    return # `initOptParser` would parse the daemon's own command line instead.
  var
    input = DefaultCliInput
    parser = initOptParser(@trnrunArgs)
  while true:
    parser.next()
    case parser.kind
    of cmdEnd:
      break
    of cmdArgument:
      raise newException(ValueError, fmt"Unexpected argument in trnrunArgs: '{parser.key}'")
    of cmdShortOption, cmdLongOption:
      if parser.key in DaemonOptions:
        raise newException(ValueError, fmt"Option not allowed in trnrunArgs: '{parser.key}'")
      let known =
        try:
          input.applyOption(parser.key, parser.val)
        except ValueError as error:
          raise newException(ValueError,
            fmt"Invalid value for '{parser.key}' in trnrunArgs: {error.msg}")
      if not known:
        raise newException(ValueError, fmt"Unknown option in trnrunArgs: '{parser.key}'")
