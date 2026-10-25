## Validates deck and TRNRun paths, and TRNRun arguments.
##
## Relative deck and TRNRun paths are both resolved from the daemon working
## directory, which a wrapper inherits by default. Decks are restricted to
## supported file types. TRNRun arguments are parsed with TRNRun's own option
## vocabulary, so a bad one is rejected when the simulation is added rather
## than when it starts. Failures raise `InputError` so the daemon can reject
## the input instead of treating it as a daemon fault.

import std/[os, parseopt, strformat, strutils]
import ../../trnrun/src/cli as trnrunCli

type InputError* = object of ValueError
  ## Input from the command line or a client was rejected; never a daemon fault.

const ReservedOptions =["deckFile", "help", "h", "version", "v"]
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

proc validateTrnrunOption(input: var trnrunCli.CliInput, key, value: string) =
  ## Raises `InputError` unless `key` is a TRNRun option outside `ReservedOptions` that takes `value`.
  if key in ReservedOptions:
    raise newException(InputError, fmt"Option not allowed in trnrunArgs: '{key}'")
  let known =
    try:
      input.applyOption(key, value)
    except ValueError as error:
      raise newException(
        InputError,
        fmt"Invalid value for '{key}' in trnrunArgs: {error.msg}",
      )
  if not known:
    raise newException(InputError, fmt"Unknown option in trnrunArgs: '{key}'")

proc validateTrnrunArgs*(trnrunArgs: openArray[string]) =
  ## Checks `trnrunArgs` before TRNRun gets them.
  ##
  ## Each argument must be an option TRNRun knows, with a value it accepts.
  ## `ReservedOptions` are refused because the daemon passes the deck itself and
  ## needs TRNRun to run. Raises `InputError` naming the first bad argument.
  if trnrunArgs.len == 0:
    return # `initOptParser` would parse the daemon's own command line instead.
  var
    input = DefaultCliInput
    parser = initOptParser(@trnrunArgs)
  for kind, key, value in parser.getopt():
    case kind
    of cmdArgument:
      raise newException(InputError, fmt"Unexpected argument in trnrunArgs: '{key}'")
    of cmdShortOption, cmdLongOption:
      input.validateTrnrunOption(key, value)
    of cmdEnd:
      discard
