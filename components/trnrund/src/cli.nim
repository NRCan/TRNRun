## Defines the TRNRun daemon command-line surface.
##
## Owns the option vocabulary: the defaults derived from the executable and
## machine, and the mapping from CLI keys onto `CliInput`.

import std/[cpuinfo, os, strutils]

type
  CliInput* = object
    ## User input gathered from the command line.
    trnrunPath*: string
    maxConcurrent*: int
    databasePath*: string

proc defaultCliInput*(): CliInput =
  ## Returns trnrun.exe beside trnrund, one worker per processor but one, and
  ## trnrund.sqlite3 in the working directory.
  result = CliInput(
    trnrunPath: getAppDir() / "trnrun.exe",
    maxConcurrent: max(countProcessors() - 1, 1),
    databasePath: "trnrund.sqlite3",
  )

proc applyOption*(input: var CliInput, key, value: string): bool =
  ## Applies one option; false if `key` is unknown, `ValueError` if `value` is bad.
  case key
  of "trnrun":
    input.trnrunPath = value
  of "maxConcurrent":
    input.maxConcurrent = parseInt(value)
  of "database":
    if value.len == 0:
      raise newException(ValueError, "'database' must not be empty")
    input.databasePath = value
  else:
    return false

  return true
